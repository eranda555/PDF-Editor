from dataclasses import asdict, dataclass
from pathlib import Path
from pdfminer.high_level import extract_pages
from pdfminer.layout import LTContainer, LTTextContainer, LTImage
from pypdf import PdfReader


@dataclass
class PageTriage:
    page: int
    route: str
    text: str
    image_area_ratio: float
    missing_cmap: bool


def walk(node):
    yield node
    if isinstance(node, LTContainer):
        for child in node:
            yield from walk(child)


def inspect_document(path: Path) -> list[PageTriage]:
    reader = PdfReader(path)
    result = []
    for number, layout in enumerate(extract_pages(path)):
        text = ''.join(node.get_text() for node in layout if isinstance(node, LTTextContainer))
        area = max(1, layout.width*layout.height)
        image_area = sum(max(0, node.width)*max(0, node.height) for node in walk(layout) if isinstance(node, LTImage))
        ratio = min(1, image_area/area)
        bad = sum(char == '\ufffd' or 0xE000 <= ord(char) <= 0xF8FF for char in text)/max(1, len(text))
        resources = reader.pages[number].get('/Resources', {})
        resources = resources.get_object() if hasattr(resources, 'get_object') else resources
        fonts = resources.get('/Font', {})
        fonts = fonts.get_object() if hasattr(fonts, 'get_object') else fonts
        # Standard base-14 fonts can map correctly without ToUnicode. A missing map
        # alone is evidence, not proof, of corrupt text encoding.
        missing = any('/ToUnicode' not in font.get_object() and
                      font.get_object().get('/Subtype') == '/Type0' for font in fonts.values())
        visible = sum(not char.isspace() for char in text)
        if bad > .05 or (missing and ('(cid:' in text or visible < 5)):
            route = 'broken_font_encoding'
        elif visible < 5:
            route = 'raster_scanned'
        elif ratio > .15:
            route = 'hybrid'
        else:
            route = 'digital_vector'
        result.append(PageTriage(number+1, route, text, ratio, missing))
    return result


def triage_report(pages: list[PageTriage]) -> list[dict]:
    return [{key: value for key, value in asdict(page).items() if key != 'text'} for page in pages]
