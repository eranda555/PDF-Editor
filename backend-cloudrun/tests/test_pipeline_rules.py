import unittest
from decimal import Decimal
from pydantic import ValidationError
from app.models import JobInit, JobOptions
from app.pipeline.layout_geometry import TextBox, xy_cut, strip_running_margins, join_words, grid_topology
from app.pipeline.layout_schema import Block, Box, Cell
from app.pipeline.table_quality import number, check_totals


class GeometryTests(unittest.TestCase):
    def test_vector_merged_cell_topology(self):
        cells=grid_topology([(0,0,20,10),(0,10,10,20),(10,10,20,20)])
        self.assertEqual(cells[0]['colspan'],2)
        self.assertEqual(cells[1]['column'],0)
        self.assertEqual(cells[2]['column'],1)

    def test_invalid_vector_grid_rejected(self):
        with self.assertRaises(ValueError):
            grid_topology([(10,0,0,10)])

    def test_column_order_before_rows(self):
        boxes=[TextBox(1,.6,.1,.9,.15,'right top'),TextBox(1,.1,.3,.4,.35,'left bottom'),
               TextBox(1,.1,.1,.4,.15,'left top'),TextBox(1,.6,.3,.9,.35,'right bottom')]
        self.assertEqual([box.text for box in xy_cut(boxes)],['left top','left bottom','right top','right bottom'])

    def test_spanning_heading_then_columns(self):
        boxes=[TextBox(1,.1,.01,.9,.05,'heading'),TextBox(1,.6,.2,.9,.3,'right'),TextBox(1,.1,.2,.4,.3,'left')]
        self.assertEqual([box.text for box in xy_cut(boxes)],['heading','left','right'])

    def test_remove_repeated_headers_and_numbered_footers(self):
        pages=[[TextBox(n,.1,.01,.8,.04,'Company'),TextBox(n,.4,.95,.6,.98,f'Page {n}'),
                TextBox(n,.1,.3,.8,.4,f'Body {n}')] for n in range(1,5)]
        self.assertEqual([[box.text for box in page] for page in strip_running_margins(pages)],[[f'Body {n}'] for n in range(1,5)])

    def test_unique_margins_preserved(self):
        pages=[[TextBox(n,.1,.01,.8,.04,text)] for n,text in enumerate(['Alpha','Beta','Gamma'],1)]
        self.assertEqual(strip_running_margins(pages),pages)

    def test_adjacent_words_joined(self):
        words=[TextBox(1,.1,.2,.15,.22,'First'),TextBox(1,.16,.2,.20,.22,'line')]
        self.assertEqual(join_words(words)[0].text,'First line')


class TableTests(unittest.TestCase):
    def test_numeric_currency_and_separators(self):
        self.assertEqual(number('$1,234.56'),Decimal('1234.56'))
        self.assertEqual(number('(12.50)'),Decimal('-12.50'))
        self.assertEqual(number('-45'),Decimal('-45'))

    def test_identifiers_and_formulas_stay_text(self):
        for value in ['00123','=1+1','+CMD()','1.2.3','1234,56','1e100','NaN']:
            self.assertIsNone(number(value))

    def test_total_tolerance(self):
        self.assertEqual(check_totals([['Subtotal','100'],['GST','10'],['Total','110.02']])['status'],'passed')
        self.assertEqual(check_totals([['Subtotal','100'],['Tax','10'],['Grand total','111']])['status'],'review_required')

    def test_missing_semantics_are_not_invented(self):
        self.assertEqual(check_totals([['A','100'],['B','10']])['status'],'not_applicable')

    def test_overlapping_cells_rejected(self):
        with self.assertRaises(ValidationError):
            Block(page=1,kind='table',text='',box=Box(x0=0,y0=0,x1=1,y1=1),cells=[
                Cell(row=0,column=0,colspan=2,text='merged'),Cell(row=0,column=1,text='overlap')])

    def test_sparse_grid_bomb_rejected_before_allocation(self):
        with self.assertRaises(ValidationError):
            Block(page=1,kind='table',text='',box=Box(x0=0,y0=0,x1=1,y1=1),cells=[Cell(row=10000,column=1000,text='bomb')])


class OptionsTests(unittest.TestCase):
    def test_supported_conversion_pair(self):
        request=JobInit(extension='docx',byte_length=100,sha256='a'*64,output_format='pdf')
        self.assertEqual(request.options.pdfa_part,2)

    def test_unsupported_pair_rejected_before_quota(self):
        with self.assertRaises(ValidationError):
            JobInit(extension='docx',byte_length=100,sha256='a'*64,output_format='xlsx')

    def test_sandbox_language_injection_rejected(self):
        for language in ['eng;curl','eng --force-ocr','../../eng','en','eng+sin+tam+fra']:
            with self.assertRaises(ValidationError):
                JobOptions(ocr_language=language)

    def test_archival_and_language_options(self):
        self.assertEqual(JobOptions(pdfa_part=1,ocr_language='eng+sin').pdfa_part,1)


if __name__=='__main__':
    unittest.main()
