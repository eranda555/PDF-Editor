import cv2
import numpy as np
import pypdfium2 as pdfium
from PIL import Image
from skimage.filters import threshold_sauvola


def render_page(path, index: int, dpi: int = 300) -> Image.Image:
    if dpi not in (72, 150, 300, 400):
        raise ValueError('Unsupported raster DPI')
    with pdfium.PdfDocument(str(path)) as document:
        page = document[index]
        try:
            width, height = page.get_size()
            if width*height*(dpi/72)**2 > 45_000_000:
                raise ValueError('Raster pixel ceiling exceeded')
            bitmap = page.render(scale=dpi/72)
            try:
                return bitmap.to_pil().convert('RGB').copy()
            finally:
                bitmap.close()
        finally:
            page.close()


def preprocess(image: Image.Image) -> tuple[Image.Image, float]:
    gray = cv2.cvtColor(np.array(image.convert('RGB')), cv2.COLOR_RGB2GRAY)
    edges = cv2.Canny(gray, 50, 150)
    lines = cv2.HoughLinesP(edges, 1, np.pi/1800, threshold=100,
                            minLineLength=max(40, gray.shape[1]//8), maxLineGap=20)
    angles = []
    if lines is not None:
        for x1, y1, x2, y2 in lines[:, 0]:
            angle = np.degrees(np.arctan2(float(y2-y1), float(x2-x1)))
            if abs(angle) < 15:
                angles.append(angle)
    angle = float(np.median(angles)) if angles else 0.0
    matrix = cv2.getRotationMatrix2D((gray.shape[1]/2, gray.shape[0]/2), angle, 1)
    deskewed = cv2.warpAffine(gray, matrix, (gray.shape[1], gray.shape[0]), borderValue=255)
    filtered = cv2.bilateralFilter(deskewed, 9, 75, 75)
    # Sauvola's floating-point integral arrays are computed in overlapping row
    # strips; allocating them for a full 45 MP page can exhaust a 1 GiB worker.
    result=np.empty_like(filtered)
    for start in range(0,filtered.shape[0],256):
        end=min(filtered.shape[0],start+256)
        top=max(0,start-15);bottom=min(filtered.shape[0],end+15)
        patch=filtered[top:bottom]
        threshold=threshold_sauvola(patch,window_size=31,k=.2)
        result[start:end]=((patch[start-top:end-top]>threshold[start-top:end-top])*255).astype(np.uint8)
    return Image.fromarray(result), angle
