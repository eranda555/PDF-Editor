import hashlib
import warnings
import zipfile
import posixpath
import stat
from pathlib import Path
from urllib.parse import unquote
from defusedxml import ElementTree
from PIL import Image

Image.MAX_IMAGE_PIXELS = 45_000_000
OOXML = {'docx': 'word/', 'xlsx': 'xl/', 'pptx': 'ppt/'}


class InvalidFile(ValueError):
    """The uploaded file failed structural validation."""


def validate_ooxml(path: Path, extension: str):
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            names = {item.filename for item in entries}
            if len(names) != len(entries) or len({name.casefold() for name in names}) != len(names):
                raise InvalidFile('Ambiguous duplicate archive entry')
            if len(entries) > 5000 or sum(item.file_size for item in entries) > 120_000_000:
                raise InvalidFile('Archive expansion limit exceeded')
            if '[Content_Types].xml' not in names or not any(name.startswith(OOXML[extension]) for name in names):
                raise InvalidFile('Invalid OOXML package type')
            for item in entries:
                if stat.S_ISLNK(item.external_attr >> 16):
                    raise InvalidFile('Archive symlinks are forbidden')
                if item.flag_bits & 1 or item.filename.startswith(('/', '\\')) or '..' in Path(item.filename.replace('\\', '/')).parts:
                    raise InvalidFile('Unsafe ZIP entry')
                if item.file_size > 30_000_000 or (item.file_size > 1_000_000 and item.file_size / max(1, item.compress_size) > 200):
                    raise InvalidFile('ZIP expansion ratio exceeded')
                if item.filename.lower().endswith(('vbaproject.bin', '.exe', '.dll')):
                    raise InvalidFile('Active content is forbidden')
                if item.filename.endswith('.rels'):
                    root = ElementTree.fromstring(archive.read(item))
                    for relation in root:
                        target = unquote(unquote(relation.attrib.get('Target', ''))).strip().lower()
                        base = posixpath.dirname(posixpath.dirname(item.filename))
                        resolved = posixpath.normpath(posixpath.join(base, target))
                        if relation.attrib.get('TargetMode', '').lower() == 'external' or ':' in target or target.startswith(('/', '\\')) or '\\' in target or resolved.startswith('../'):
                            raise InvalidFile('External relationships are forbidden')
    except (zipfile.BadZipFile, KeyError) as exc:
        raise InvalidFile('Corrupt OOXML archive') from exc


def validate_file(path: Path, extension: str, expected_size: int | None = None,
                  expected_hash: str | None = None, max_pages: int = 20):
    size = path.stat().st_size
    if size < 1 or size > 15_728_640 or (expected_size is not None and size != expected_size):
        raise InvalidFile('File length mismatch or size limit exceeded')
    if expected_hash:
        with path.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != expected_hash:
                raise InvalidFile('SHA-256 mismatch')
    with path.open('rb') as stream:
        head = stream.read(512)
    if extension == 'pdf':
        from pypdf import PdfReader
        if not head.startswith((b'%PDF-1.', b'%PDF-2.')):
            raise InvalidFile('PDF signature mismatch')
        try:
            reader = PdfReader(path, strict=True)
            if reader.is_encrypted:
                raise InvalidFile('Decrypt password-protected files on-device before upload')
            objects = sum(len(items) for items in reader.xref.values()) + len(reader.xref_objStm)
            if objects > 50_000 or int(reader.trailer['/Size']) > 50_000:
                raise InvalidFile('PDF object limit exceeded')
            if not 1 <= len(reader.pages) <= max_pages:
                raise InvalidFile('PDF page limit exceeded')
            for page in reader.pages:
                width, height = float(page.mediabox.width), float(page.mediabox.height)
                user_unit = float(page.get('/UserUnit', 1))
                if not 0 < width*user_unit <= 2880 or not 0 < height*user_unit <= 2880:
                    raise InvalidFile('Oversized PDF page')
                if width*height*user_unit*user_unit*(400/72)**2 > 45_000_000:
                    raise InvalidFile('PDF raster pixel limit exceeded')
            return len(reader.pages)
        except InvalidFile:
            raise
        except Exception as exc:
            raise InvalidFile('Invalid PDF structure') from exc
    if extension in OOXML:
        if not head.startswith(b'PK\x03\x04'):
            raise InvalidFile('OOXML signature mismatch')
        validate_ooxml(path, extension)
        return 0
    if extension in {'doc','xls','ppt'}:
        from app.security.legacy_office import validate_legacy
        validate_legacy(path,extension)
        return 0
    if extension in {'png', 'jpg', 'jpeg', 'webp', 'tif', 'tiff'}:
        formats = {'png': 'PNG', 'jpg': 'JPEG', 'jpeg': 'JPEG', 'webp': 'WEBP', 'tif': 'TIFF', 'tiff': 'TIFF'}
        with warnings.catch_warnings():
            warnings.simplefilter('error', Image.DecompressionBombWarning)
            with Image.open(path) as image:
                if image.format != formats[extension] or image.width*image.height > 45_000_000:
                    raise InvalidFile('Image signature mismatch or pixel limit exceeded')
                if getattr(image, 'n_frames', 1) > max_pages:
                    raise InvalidFile('Image frame limit exceeded')
                image.verify()
        return 1
    if extension in {'txt', 'md', 'html', 'tex'}:
        try:
            text = path.read_text(encoding='utf-8')
        except UnicodeError as exc:
            raise InvalidFile('Text input must be UTF-8') from exc
        if '\x00' in text:
            raise InvalidFile('Binary content in text file')
        return 0
    raise InvalidFile('Unsupported input file type')
