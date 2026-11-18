"""Reading-order reconstruction without invoking OCR on valid digital text."""
from dataclasses import dataclass, replace
import re


@dataclass(frozen=True)
class TextBox:
    page: int
    x0: float
    y0: float
    x1: float
    y1: float
    text: str
    font_size: float = 12
    kind: str = 'paragraph'


def xy_cut(boxes: list[TextBox], depth: int = 0) -> list[TextBox]:
    if len(boxes) < 2 or depth > 40:
        return sorted(boxes, key=lambda box: (box.y0, box.x0))
    # A true whitespace corridor must intersect no box. Prefer columns when the
    # gap is at least 2% of a normalized page; otherwise cut between rows.
    for axis, threshold in (('x', .02), ('y', .008)):
        ordered = sorted(boxes, key=lambda box: getattr(box, axis+'0'))
        end = getattr(ordered[0], axis+'1')
        cuts = []
        for index in range(1, len(ordered)):
            start = getattr(ordered[index], axis+'0')
            if start-end > threshold:
                cuts.append((start-end, index))
            end = max(end, getattr(ordered[index], axis+'1'))
        if cuts:
            _, split = max(cuts)
            return xy_cut(ordered[:split], depth+1)+xy_cut(ordered[split:], depth+1)
    return sorted(boxes, key=lambda box: (round(box.y0/.008), box.x0))


def strip_running_margins(pages: list[list[TextBox]]) -> list[list[TextBox]]:
    if len(pages) < 3:
        return pages
    def fingerprint(text):
        return re.sub(r'\d+', '#', re.sub(r'\s+', ' ', text.strip().lower()))
    occurrences: dict[tuple[str, str], set[int]] = {}
    for page in pages:
        for box in page:
            band = 'header' if box.y1 < .09 else 'footer' if box.y0 > .91 else ''
            if band and box.text.strip():
                occurrences.setdefault((band, fingerprint(box.text)), set()).add(box.page)
    repeated = {key for key, members in occurrences.items() if len(members) >= max(3, int(len(pages)*.6+.5))}
    return [[box for box in page if
             ('header' if box.y1 < .09 else 'footer' if box.y0 > .91 else '', fingerprint(box.text)) not in repeated]
            for page in pages]


def join_words(words: list[TextBox]) -> list[TextBox]:
    """Merge adjacent words into lines after column separation."""
    ordered = xy_cut(words)
    lines: list[TextBox] = []
    for word in ordered:
        if lines:
            previous = lines[-1]
            if previous.page == word.page and abs(previous.y0-word.y0) < .004 and 0 <= word.x0-previous.x1 < .03:
                lines[-1] = replace(previous, x1=max(previous.x1, word.x1), y1=max(previous.y1, word.y1),
                                    text=previous.text+' '+word.text)
                continue
        lines.append(word)
    return lines


def grid_topology(rectangles: list[tuple[float,float,float,float]]) -> list[dict]:
    """Recover merged cells from vector border intersections, without OCR."""
    if not rectangles or len(rectangles)>10000:
        raise ValueError('Table cell count outside limits')
    boxes=[tuple(round(value,3) for value in box) for box in rectangles]
    xs=sorted({value for box in boxes for value in (box[0],box[2])})
    ys=sorted({value for box in boxes for value in (box[1],box[3])})
    if (len(xs)-1)*(len(ys)-1)>20000:
        raise ValueError('Table grid exceeds limits')
    columns={value:index for index,value in enumerate(xs)}
    rows={value:index for index,value in enumerate(ys)}
    result=[]
    for index,(left,top,right,bottom) in enumerate(boxes):
        if left>=right or top>=bottom:
            raise ValueError('Invalid table cell bounds')
        result.append({'index':index,'row':rows[top],'column':columns[left],
            'rowspan':rows[bottom]-rows[top],'colspan':columns[right]-columns[left]})
    return result
