from pathlib import Path
import shutil
import os
from PIL import Image, ImageSequence
from playwright.async_api import async_playwright
from app.pipeline.process import run_process
from app.pipeline.phase3_light_engines import convert_light, save_image_pdf
from app.pipeline.phase4_qa_verify import visual_diff
from app.security.file_validator import validate_file
from worker_app.security_sandbox import inspect_office, sanitized_html, block_network


async def office(source: Path, root: Path, target: str) -> Path:
    if source.suffix.lstrip('.') in {'docx','xlsx','pptx'}:
        inspect_office(source)
    destination = root/'office-export'
    destination.mkdir(exist_ok=True)
    profile = (root/'lo-profile').as_uri()
    user_profile=root/'lo-profile'/'user'
    user_profile.mkdir(parents=True,exist_ok=True)
    (user_profile/'registrymodifications.xcu').write_text(
        '<?xml version="1.0"?><oor:items xmlns:oor="http://openoffice.org/2001/registry">'
        '<item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item></oor:items>',encoding='utf-8')
    # Legacy binary inputs are rejected by validation before reaching LibreOffice.
    # Run the entire heavy container without outbound network access in Compose.
    await run_process(['soffice', f'-env:UserInstallation={profile}', '--norestore',
        '--nolockcheck', '--nodefault', '--headless', '--convert-to', target,
        '--outdir', str(destination), str(source)], root, 150)
    result = destination/(source.stem+'.'+target.split(':')[0])
    if not result.is_file():
        raise ValueError('Office exporter produced no output')
    return result


async def html_pdf(source: Path, output: Path):
    clean = sanitized_html(source.read_text(encoding='utf-8'))
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(headless=True, chromium_sandbox=True, args=['--disable-dev-shm-usage'],
            env={'PATH':os.environ.get('PATH','/usr/local/bin:/usr/bin:/bin'),'HOME':str(output.parent),'TMPDIR':str(output.parent),'LANG':'C.UTF-8'})
        try:
            context = await browser.new_context(java_script_enabled=False, service_workers='block')
            await context.route('**/*', block_network)
            page = await context.new_page()
            await page.set_content('<!doctype html><html><head><style>body{margin:0}</style></head><body>'+clean+'</body></html>', wait_until='domcontentloaded', timeout=15000)
            await page.emulate_media(media='print')
            await page.pdf(path=str(output), format='A4', print_background=True, timeout=30000)
            await context.close()
        finally:
            await browser.close()


async def convert(source: Path, output: Path, format_name: str, settings, options=None) -> dict:
    options=options or {}
    root = output.parent
    extension = source.suffix.lstrip('.')
    report = {'engine': format_name}
    if format_name == 'pdf':
        if extension in {'docx','xlsx','pptx','doc','xls','ppt'}:
            shutil.copyfile(await office(source, root, 'pdf'), output)
        elif extension == 'html':
            await html_pdf(source, output)
        elif extension in {'md', 'txt', 'tex'}:
            if extension == 'txt':
                import html
                escaped = root/'text.html'
                escaped.write_text('<pre>'+html.escape(source.read_text(encoding='utf-8'))+'</pre>', encoding='utf-8')
                await html_pdf(escaped, output)
            else:
                await run_process(['pandoc', '--sandbox', '--from', 'latex' if extension=='tex' else 'markdown',
                '--pdf-engine=typst', str(source), '-o', str(output)], root)
        elif extension in {'png','jpg','jpeg','webp','tif','tiff'}:
            images = []
            try:
                with Image.open(source) as image:
                    for frame in ImageSequence.Iterator(image):
                        images.append(frame.copy())
                save_image_pdf(images, output)
            finally:
                for image in images:
                    image.close()
        elif extension == 'pdf':
            shutil.copyfile(source, output)
        else:
            raise ValueError('Unsupported input for PDF export')
    elif format_name in {'searchable_pdf', 'pdfa'}:
        if extension != 'pdf':
            raise ValueError('OCR and archival output require PDF input')
        part=options.get('pdfa_part',2)
        language=options.get('ocr_language','eng')
        args = ['ocrmypdf', '--skip-text', '--output-type', f'pdfa-{part}', '--jobs', '1','--language',language,
                '--tesseract-timeout', '45', '--max-image-mpixels', '45', str(source), str(output)]
        await run_process(args, root, 210)
        from pypdf import PdfReader
        count = len(PdfReader(source).pages)
        report['visual_qa'] = visual_diff(source, output, count)
        report['archival_validation'] = f'OCRmyPDF PDF/A-{part} output; independent veraPDF conformance audit required'
    elif format_name in {'mobi','azw3'}:
        intermediate=root/'book.docx'
        report=await convert_light(source,intermediate,'docx',settings,options)
        await run_process(['ebook-convert',str(intermediate),str(output)],root,180)
    elif format_name=='dwg':
        intermediate=root/'drawing.dxf'
        report=await convert_light(source,intermediate,'dxf',settings,options)
        await run_process(['dxf2dwg','--as=r2000','-o',str(output),str(intermediate)],root,180)
        if not output.is_file():
            raise ValueError('DWG export did not produce a valid drawing header')
        with output.open('rb') as stream:
            if not stream.read(6).startswith(b'AC10'):
                raise ValueError('DWG export did not produce a valid drawing header')
    elif format_name in {'doc','odt','rtf','xls','ppt','epub'}:
        if extension != 'pdf':
            raise ValueError('This conversion requires PDF input')
        intermediate_format = 'xlsx' if format_name == 'xls' else 'pptx' if format_name == 'ppt' else 'docx'
        intermediate = root/('editable.'+intermediate_format)
        report = await convert_light(source, intermediate, intermediate_format, settings)
        if format_name == 'epub':
            await run_process(['pandoc', '--sandbox', str(intermediate), '-o', str(output)], root)
        else:
            shutil.copyfile(await office(intermediate, root, format_name), output)
    elif format_name in {'txt','md','json','xml','docx','xlsx','csv','html','pptx'} and extension=='pdf':
        report=await convert_light(source,output,format_name,settings,options)
    else:
        raise ValueError('Conversion is not supported by the heavy worker')
    if format_name in {'pdf','pdfa','searchable_pdf'}:
        validate_file(output, 'pdf')
    if extension=='pdf' and format_name in {'docx','xlsx','pptx','doc','xls','ppt','odt','rtf'}:
        roundtrip=await office(output,root,'pdf')
        from pypdf import PdfReader
        source_count=len(PdfReader(source).pages)
        output_count=len(PdfReader(roundtrip).pages)
        qa=visual_diff(source,roundtrip,min(source_count,output_count))
        qa['source_pages']=source_count;qa['output_pages']=output_count
        qa['flagged']=qa['flagged'] or source_count!=output_count
        report['visual_qa']=qa
    return report
