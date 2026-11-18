import re
import unicodedata
from decimal import Decimal
import numpy as np
from PIL import Image
from skimage.metrics import structural_similarity
from app.pipeline.phase2_preprocess import render_page


def normalize_text(text: str) -> str:
    text = unicodedata.normalize('NFKC', text).replace('\ufffd', '')
    return re.sub(r'(?<=\w)-\r?\n(?=[a-z])', '', text)


def check_total(subtotal: str, tax: str, total: str) -> bool:
    return abs(Decimal(subtotal)+Decimal(tax)-Decimal(total)) <= Decimal('0.02')


def visual_diff(source, output, page_count: int) -> dict:
    scores = []
    for index in range(page_count):
        with render_page(source, index, 150) as left, render_page(output, index, 150) as right:
            same_size = left.size == right.size
            a = np.asarray(left.convert('L'))
            b = np.asarray(right.convert('L').resize(left.size, Image.Resampling.LANCZOS))
            score = float(structural_similarity(a, b, data_range=255))
            scores.append({'page': index+1, 'ssim': score, 'same_dimensions': same_size,
                           'layout_drift': score < .85 or not same_size})
    return {'pages': scores, 'flagged': any(page['layout_drift'] for page in scores)}
