from enum import StrEnum
from typing import Literal
from uuid import UUID
from pydantic import BaseModel, ConfigDict, Field, model_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra='forbid')


class OutputFormat(StrEnum):
    txt = 'txt'
    md = 'md'
    json = 'json'
    xml = 'xml'
    docx = 'docx'
    xlsx = 'xlsx'
    csv = 'csv'
    pptx = 'pptx'
    svg = 'svg'
    html = 'html'
    dxf = 'dxf'
    pdf = 'pdf'
    searchable_pdf = 'searchable_pdf'
    pdfa = 'pdfa'
    flattened_pdf = 'flattened_pdf'
    epub = 'epub'
    rtf = 'rtf'
    odt = 'odt'
    doc = 'doc'
    xls = 'xls'
    ppt = 'ppt'
    mobi = 'mobi'
    azw3 = 'azw3'
    dwg = 'dwg'


class JobOptions(StrictModel):
    pdfa_part: Literal[1,2] = 2
    ocr_language: str = Field(default='eng',pattern=r'^[a-z]{3}(?:\+[a-z]{3}){0,2}$')
    presentation_mode: Literal['editable','facsimile'] = 'editable'


class JobInit(StrictModel):
    extension: str = Field(pattern=r'^(pdf|docx|xlsx|pptx|doc|xls|ppt|html|txt|md|tex|png|jpg|jpeg|webp|tif|tiff)$')
    byte_length: int = Field(gt=0, le=15_728_640)
    sha256: str = Field(pattern=r'^[a-f0-9]{64}$')
    output_format: OutputFormat
    options: JobOptions = Field(default_factory=JobOptions)

    @model_validator(mode='after')
    def supported_pair(self):
        if self.extension!='pdf' and self.output_format!=OutputFormat.pdf:
            raise ValueError('Non-PDF inputs currently convert to PDF only')
        return self


class Dispatch(StrictModel):
    job_id: UUID


class WorkerRequest(StrictModel):
    job_id: UUID
    input_url: str = Field(max_length=4096)
    input_extension: str = Field(pattern=r'^[a-z0-9]{2,5}$')
    output_format: OutputFormat
    sha256: str = Field(pattern=r'^[a-f0-9]{64}$')
    byte_length: int = Field(gt=0, le=15_728_640)
