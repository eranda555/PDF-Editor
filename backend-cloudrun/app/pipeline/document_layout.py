from io import BytesIO
from statistics import median
import pdfplumber
from PIL import ImageDraw
from app.pipeline.layout_geometry import TextBox, join_words, strip_running_margins, xy_cut, grid_topology
from app.pipeline.layout_schema import Layout, Block, Box, Cell
from app.pipeline.phase2_preprocess import render_page, preprocess
from app.pipeline.phase3_gemini_vlm import extract_content


def normalized(box, width, height):
    x0,y0,x1,y1 = box
    return Box(x0=max(0,x0/width), y0=max(0,y0/height), x1=min(1,x1/width), y1=min(1,y1/height))


def vector_blocks(page, number: int) -> list[Block]:
    tables = page.find_tables()
    blocks = []
    for table in tables:
        rows = table.extract()
        cells=[]
        for position in grid_topology(table.cells):
            bounds=table.cells[position['index']]
            text=page.within_bbox(bounds).extract_text() or ''
            cells.append(Cell(row=position['row'],column=position['column'],rowspan=position['rowspan'],colspan=position['colspan'],text=text))
        if cells:
            blocks.append(Block(page=number, kind='table', text='\n'.join(' | '.join(str(value or '') for value in row) for row in rows),
                                box=normalized(table.bbox,page.width,page.height), cells=cells))
    words = []
    for word in page.extract_words(extra_attrs=['size']):
        center = ((word['x0']+word['x1'])/2,(word['top']+word['bottom'])/2)
        if any(table.bbox[0]<=center[0]<=table.bbox[2] and table.bbox[1]<=center[1]<=table.bbox[3] for table in tables):
            continue
        words.append(TextBox(number,word['x0']/page.width,word['top']/page.height,
            word['x1']/page.width,word['bottom']/page.height,word['text'],float(word.get('size',12))))
    typical = median([word.font_size for word in words]) if words else 12
    for line in join_words(words):
        blocks.append(Block(page=number,kind='heading' if line.font_size>typical*1.2 else 'paragraph',text=line.text,
                            box=Box(x0=line.x0,y0=line.y0,x1=line.x1,y1=line.y1)))
    return blocks


async def reconstruct(path, triage, settings) -> Layout:
    """Preserve vector text verbatim; only send raster regions to visual extraction."""
    blocks = []; warnings = []
    with pdfplumber.open(path) as pdf:
        digital = [vector_blocks(page,index+1) if triage[index].route in {'digital_vector','hybrid'} else []
                   for index,page in enumerate(pdf.pages)]
        margin_pages = [[TextBox(block.page,block.box.x0,block.box.y0,block.box.x1,block.box.y1,block.text) for block in page]
                        for page in digital]
        retained = strip_running_margins(margin_pages)
        for index, page in enumerate(pdf.pages):
            accepted = {(box.text,box.x0,box.y0) for box in retained[index]}
            blocks.extend(block for block in digital[index] if (block.text,block.box.x0,block.box.y0) in accepted)
            route = triage[index].route
            if route == 'digital_vector':
                continue
            regions = [(0.,0.,float(page.width),float(page.height))] if route != 'hybrid' else [
                (max(0,image['x0']),max(0,image['top']),min(page.width,image['x1']),min(page.height,image['bottom']))
                for image in page.images if image['width']*image['height']>144]
            if len(regions)>50:
                raise ValueError('Raster region count exceeds limit')
            heights = [char['bottom']-char['top'] for char in page.chars if char['bottom']>char['top']]
            dpi = 400 if heights and median(heights)<7 else 300
            with render_page(path,index,dpi) as image:
                scale = dpi/72
                if route == 'hybrid':
                    draw = ImageDraw.Draw(image)
                    for char in page.chars:
                        draw.rectangle((max(0,char['x0']*scale-2),max(0,char['top']*scale-2),
                            min(image.width,char['x1']*scale+2),min(image.height,char['bottom']*scale+2)),fill='white')
                for x0,y0,x1,y1 in regions:
                    if x1<=x0 or y1<=y0:
                        continue
                    with image.crop((int(x0*scale),int(y0*scale),int(x1*scale),int(y1*scale))) as crop:
                        prepared, angle = preprocess(crop)
                        try:
                            stream = BytesIO();prepared.save(stream,format='PNG')
                            extracted = await extract_content(stream.getvalue(),'image/png',settings)
                        finally:
                            prepared.close()
                        for block in extracted.blocks:
                            box = block.box
                            blocks.append(block.model_copy(update={'page':index+1,'box':normalized(
                                (x0+box.x0*(x1-x0),y0+box.y0*(y1-y0),x0+box.x1*(x1-x0),y0+box.y1*(y1-y0)),page.width,page.height)}))
                        warnings.extend(extracted.warnings)
                        if abs(angle)>.1:
                            warnings.append(f'Page {index+1}: raster region deskewed {angle:.2f} degrees; citations are approximate after deskew')
    ordered=[]
    for page_number in range(1,len(triage)+1):
        page_blocks=[block for block in blocks if block.page==page_number]
        # Carry indexes through the geometry sorter to preserve table cells.
        indexed=[TextBox(page_number,block.box.x0,block.box.y0,block.box.x1,block.box.y1,str(i)) for i,block in enumerate(page_blocks)]
        ordered.extend(page_blocks[int(box.text)] for box in xy_cut(indexed))
    return Layout(blocks=ordered,warnings=list(dict.fromkeys(warnings))[:100])
