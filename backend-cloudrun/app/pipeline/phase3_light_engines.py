import csv
import html
import json
import copy
import xml.etree.ElementTree as ET
from pathlib import Path
import ezdxf
import pdfplumber
import pypdfium2 as pdfium
from docx import Document
from openpyxl import Workbook
from PIL import Image, ImageOps
from pptx import Presentation
from pptx.util import Inches, Pt
from app.pipeline.phase1_triage import inspect_document, triage_report
from app.pipeline.phase2_preprocess import render_page
from app.pipeline.document_layout import reconstruct
from app.pipeline.table_quality import number, check_totals
from app.pipeline.phase4_qa_verify import normalize_text
from app.pipeline.process import run_process


HEAVY_FORMATS = {'pdf', 'searchable_pdf', 'pdfa', 'epub', 'rtf', 'odt', 'doc', 'xls', 'ppt', 'mobi', 'azw3', 'dwg', 'docx', 'xlsx', 'pptx'}


def write_text_cell(cell, value):
    # Force an Excel string: uploaded text must never become an executable formula.
    numeric = number(value)
    if numeric is not None and len(numeric.as_tuple().digits)<=15:
        cell.value = float(numeric)
        cell.data_type = 'n'
    else:
        cell.value = str(value) if value is not None else ''
        cell.data_type = 's'


def csv_safe(value) -> str:
    text = str(value if value is not None else '')
    if number(text) is not None:
        return text
    return "'"+text if text.lstrip().startswith(('=', '+', '-', '@', '\t', '\r')) else text


def save_image_pdf(images: list[Image.Image], output: Path):
    converted = [ImageOps.exif_transpose(image).convert('RGB') for image in images]
    try:
        if not converted:
            raise ValueError('No images to export')
        converted[0].save(output, 'PDF', save_all=True, append_images=converted[1:], resolution=150)
    finally:
        for image in converted:
            image.close()


async def convert_light(source: Path, output: Path, format_name: str, settings, options=None) -> dict:
    options = options or {}
    pages = inspect_document(source)
    report = {'triage': triage_report(pages), 'qa': {'visual_comparison': 'not_applicable_to_editable_output'}}
    layout = None
    if format_name in {'md', 'json', 'xml', 'docx', 'txt', 'xlsx', 'csv', 'html'} or (format_name=='pptx' and options.get('presentation_mode','editable')=='editable'):
        layout = await reconstruct(source, pages, settings)
        text = '\n\n'.join(block.text for block in layout.blocks)
        report['warnings'] = layout.warnings
        if any(page.route!='digital_vector' for page in pages):
            report['warnings'].append('AI transcription requires user review')
    else:
        text = '\n\n'.join(page.text for page in pages)
    text = normalize_text(text)
    if format_name in {'txt', 'md'}:
        if format_name == 'md' and layout:
            text = '\n\n'.join(('# ' if block.kind == 'heading' else '')+block.text for block in layout.blocks)
        output.write_text(text, encoding='utf-8')
    elif format_name == 'json':
        payload = layout.model_dump() if layout else {'pages': [{'page': page.page, 'text': normalize_text(page.text)} for page in pages]}
        output.write_text(json.dumps(payload, ensure_ascii=False), encoding='utf-8')
    elif format_name == 'xml':
        root = ET.Element('document')
        if layout:
            for block in layout.blocks:
                node = ET.SubElement(root, block.kind, page=str(block.page))
                node.text = block.text
        else:
            for page in pages:
                ET.SubElement(root, 'page', number=str(page.page)).text = normalize_text(page.text)
        ET.ElementTree(root).write(output, encoding='utf-8', xml_declaration=True)
    elif format_name == 'html':
        output.write_text('<!doctype html><html><meta charset="utf-8"><title>Converted document</title><body>'+''.join(
            '<p>'+html.escape(paragraph)+'</p>' for paragraph in text.split('\n\n'))+'</body></html>', encoding='utf-8')
    elif format_name == 'docx':
        document = Document()
        if layout:
            for block in layout.blocks:
                if block.kind == 'heading':
                    document.add_heading(block.text, level=1)
                elif block.kind == 'table' and block.cells:
                    rows = max(cell.row+cell.rowspan for cell in block.cells)
                    columns = max(cell.column+cell.colspan for cell in block.cells)
                    if rows*columns > 20000:
                        raise ValueError('Table dimensions exceed limits')
                    table = document.add_table(rows=rows, cols=columns)
                    for cell in block.cells:
                        target = table.cell(cell.row, cell.column)
                        if cell.rowspan > 1 or cell.colspan > 1:
                            target = target.merge(table.cell(cell.row+cell.rowspan-1, cell.column+cell.colspan-1))
                        target.text = cell.text
                elif block.kind=='math':
                    equation_source=output.parent/'equation.md'
                    equation_output=output.parent/'equation.docx'
                    equation_source.write_text('$$\n'+block.text.strip().strip('$')+'\n$$',encoding='utf-8')
                    await run_process(['pandoc','--sandbox','--from=markdown','--to=docx',str(equation_source),'-o',str(equation_output)],output.parent)
                    equation_document=Document(equation_output)
                    paragraph=document.add_paragraph()
                    count=0
                    for node in equation_document.element.body.iter():
                        if node.tag=='{http://schemas.openxmlformats.org/officeDocument/2006/math}oMath':
                            paragraph._p.append(copy.deepcopy(node));count+=1
                    if count==0:
                        raise ValueError('Equation conversion produced no editable Office Math')
                else:
                    document.add_paragraph(block.text)
        else:
            for page in pages:
                for paragraph in normalize_text(page.text).split('\n\n'):
                    document.add_paragraph(paragraph)
                if page.page < len(pages):
                    document.add_page_break()
        document.core_properties.author = ''
        document.core_properties.last_modified_by = ''
        document.save(output)
        report['warnings'] = report.get('warnings', [])+['DOCX preserves extracted text, not exact source typography or pagination']
    elif format_name in {'xlsx', 'csv'}:
        tables = []
        if layout:
            for block in layout.blocks:
                if block.kind == 'table' and block.cells:
                    tables.append(block.cells)
        else:
            with pdfplumber.open(source) as pdf:
                for page in pdf.pages:
                    tables.extend(page.extract_tables())
        if not tables:
            raise ValueError('No tables detected')
        workbook = Workbook()
        workbook.remove(workbook.active)
        csv_rows = []
        arithmetic = []
        for index, table in enumerate(tables):
            sheet = workbook.create_sheet(f'Table {index+1}')
            if layout:
                max_row = max(cell.row+cell.rowspan for cell in table)
                max_col = max(cell.column+cell.colspan for cell in table)
                if max_row*max_col > 20000:
                    raise ValueError('Table dimensions exceed limits')
                for cell in table:
                    write_text_cell(sheet.cell(cell.row+1, cell.column+1), cell.text)
                    if cell.rowspan > 1 or cell.colspan > 1:
                        sheet.merge_cells(start_row=cell.row+1, start_column=cell.column+1,
                            end_row=cell.row+cell.rowspan, end_column=cell.column+cell.colspan)
            else:
                for r, row in enumerate(table, 1):
                    for c, value in enumerate(row, 1):
                        write_text_cell(sheet.cell(r, c), value)
            rows = [list(row) for row in sheet.iter_rows(values_only=True)]
            arithmetic.append({'table':index+1,**check_totals(rows)})
            csv_rows.extend(rows)
            csv_rows.append([])
        if format_name == 'xlsx':
            workbook.save(output)
        else:
            with output.open('w', encoding='utf-8', newline='') as stream:
                csv.writer(stream).writerows([[csv_safe(cell) for cell in row] for row in csv_rows])
        report['qa']['arithmetic'] = arithmetic
    elif format_name in {'flattened_pdf', 'pptx'}:
        if format_name == 'pptx':
            deck = Presentation()
            with pdfium.PdfDocument(str(source)) as pdf:
                first_page = pdf[0]
                try:
                    width, height = first_page.get_size()
                finally:
                    first_page.close()
            deck.slide_width, deck.slide_height = Inches(width/72), Inches(height/72)
            for index in range(len(pages)):
                slide = deck.slides.add_slide(deck.slide_layouts[6])
                if layout is None:
                    image_path = output.parent/f'page-{index}.png'
                    with render_page(source, index, 150) as image:
                        image.save(image_path)
                    slide.shapes.add_picture(str(image_path), 0, 0, width=deck.slide_width, height=deck.slide_height)
                else:
                    for block in layout.blocks:
                        if block.page!=index+1:
                            continue
                        x,y=int(block.box.x0*deck.slide_width),int(block.box.y0*deck.slide_height)
                        w,h=max(1,int((block.box.x1-block.box.x0)*deck.slide_width)),max(1,int((block.box.y1-block.box.y0)*deck.slide_height))
                        if block.kind=='table' and block.cells:
                            rows=max(cell.row+cell.rowspan for cell in block.cells)
                            columns=max(cell.column+cell.colspan for cell in block.cells)
                            table=slide.shapes.add_table(rows,columns,x,y,w,h).table
                            for cell in block.cells:
                                target=table.cell(cell.row,cell.column)
                                if cell.rowspan>1 or cell.colspan>1:
                                    target.merge(table.cell(cell.row+cell.rowspan-1,cell.column+cell.colspan-1))
                                target.text=cell.text
                        else:
                            frame=slide.shapes.add_textbox(x,y,w,max(h,Pt(14))).text_frame
                            frame.word_wrap=True
                            frame.margin_left=frame.margin_right=frame.margin_top=frame.margin_bottom=0
                            frame.text=block.text
                            for paragraph in frame.paragraphs:
                                paragraph.font.size=Pt(20 if block.kind=='heading' else 11)
                                paragraph.font.bold=block.kind=='heading'
            deck.save(output)
            report['warnings'] = ['Slides contain page images; text is not editable'] if layout is None else report.get('warnings',[])+['Editable text and tables reconstructed; original graphics and typography require review']
        else:
            await run_process(['qpdf','--generate-appearances','--flatten-annotations=all',str(source),str(output)],output.parent)
            from app.pipeline.phase4_qa_verify import visual_diff
            report['qa']['visual_comparison']=visual_diff(source,output,len(pages))
    elif format_name == 'svg':
        import zipfile
        with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
            for page in pages:
                target = output.parent/f'page-{page.page}.svg'
                await run_process(['pdftocairo', '-svg', '-f', str(page.page), '-l', str(page.page), str(source), str(target)], output.parent)
                archive.write(target, target.name)
        report['container'] = 'zip'
    elif format_name == 'dxf':
        drawing = ezdxf.new('R2010')
        model = drawing.modelspace()
        with pdfplumber.open(source) as pdf:
            offset = 0.0
            for page in pdf.pages:
                for line in page.lines:
                    model.add_line((line['x0']+offset, line['y0']), (line['x1']+offset, line['y1']))
                for rect in page.rects:
                    x0, y0, x1, y1 = rect['x0']+offset, rect['y0'], rect['x1']+offset, rect['y1']
                    model.add_lwpolyline([(x0,y0),(x1,y0),(x1,y1),(x0,y1)], close=True)
                for curve in page.curves:
                    points=[(point[0]+offset,page.height-point[1]) for point in curve.get('pts',[])]
                    if len(points)>1:
                        model.add_lwpolyline(points,close=points[0]==points[-1])
                for word in page.extract_words():
                    model.add_text(word['text'],dxfattribs={'height':max(1,word['bottom']-word['top']),
                        'insert':(word['x0']+offset,page.height-word['bottom'])})
                offset += page.width+72
        drawing.saveas(output)
        report['warnings'] = ['DXF exports lines, rectangles, curve control polygons and text in PDF-point units. Curve interpolation and CAD semantics require review']
    else:
        raise ValueError('Format requires the isolated heavy converter')
    return report
