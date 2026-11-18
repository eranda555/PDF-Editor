import tempfile
import unittest
import zipfile
from pathlib import Path
from PIL import Image
from app.security.file_validator import InvalidFile, validate_file


class FileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def pdf(self, count: int) -> Path:
        from pypdf import PdfWriter
        path = self.root/'document.pdf'
        writer = PdfWriter()
        for _ in range(count):
            writer.add_blank_page(width=595, height=842)
        writer.write(path)
        writer.close()
        return path

    def test_pdf_page_limit(self):
        self.assertEqual(validate_file(self.pdf(20), 'pdf'), 20)
        with self.assertRaises(InvalidFile):
            validate_file(self.pdf(21), 'pdf')

    def test_hash_mismatch(self):
        with self.assertRaises(InvalidFile):
            validate_file(self.pdf(1), 'pdf', expected_hash='0'*64)

    def test_extension_spoof(self):
        path = self.root/'fake.pdf'
        path.write_bytes(b'not a PDF')
        with self.assertRaises(InvalidFile):
            validate_file(path, 'pdf')

    def test_external_ooxml_relationship(self):
        path = self.root/'attack.docx'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('[Content_Types].xml', '<Types/>')
            archive.writestr('word/document.xml', '<document/>')
            archive.writestr('word/_rels/document.xml.rels', '<Relationships><Relationship TargetMode="External" Target="http://169.254.169.254/"/></Relationships>')
        with self.assertRaises(InvalidFile):
            validate_file(path, 'docx')

    def test_zip_path_traversal(self):
        path = self.root/'attack.docx'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('[Content_Types].xml', '<Types/>')
            archive.writestr('word/document.xml', '<document/>')
            archive.writestr('../escape', 'data')
        with self.assertRaises(InvalidFile):
            validate_file(path, 'docx')

    def test_image_signature(self):
        path = self.root/'image.png'
        with Image.new('RGB', (10,10), 'white') as image:
            image.save(path)
        self.assertEqual(validate_file(path, 'png'), 1)
        with self.assertRaises(InvalidFile):
            validate_file(path, 'jpg')

    def test_binary_text_rejected(self):
        path = self.root/'bad.txt'
        path.write_bytes(b'hello\x00world')
        with self.assertRaises(InvalidFile):
            validate_file(path, 'txt')

    def test_encoded_external_relationship(self):
        path = self.root/'encoded.docx'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('[Content_Types].xml', '<Types/>')
            archive.writestr('word/document.xml', '<document/>')
            archive.writestr('word/_rels/document.xml.rels', '<Relationships><Relationship Target="%66ile%3A///etc/passwd"/></Relationships>')
        with self.assertRaises(InvalidFile):
            validate_file(path, 'docx')

    def test_valid_office_archive(self):
        path = self.root/'document.docx'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('[Content_Types].xml', '<Types/>')
            archive.writestr('word/document.xml', '<document/>')
        self.assertEqual(validate_file(path, 'docx'), 0)

    def test_size_mismatch(self):
        path = self.root/'data.txt'
        path.write_text('document')
        with self.assertRaises(InvalidFile):
            validate_file(path, 'txt', expected_size=9)


if __name__ == '__main__':
    unittest.main()
