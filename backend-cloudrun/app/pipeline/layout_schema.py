from typing import Literal
from pydantic import BaseModel, ConfigDict, Field, model_validator


class Box(BaseModel):
    x0: float = Field(ge=0, le=1)
    y0: float = Field(ge=0, le=1)
    x1: float = Field(ge=0, le=1)
    y1: float = Field(ge=0, le=1)

    @model_validator(mode='after')
    def ordered(self):
        if self.x0 >= self.x1 or self.y0 >= self.y1:
            raise ValueError('Bounding boxes must have positive area')
        return self


class Cell(BaseModel):
    row: int = Field(ge=0, le=10000)
    column: int = Field(ge=0, le=1000)
    rowspan: int = Field(default=1, ge=1, le=100)
    colspan: int = Field(default=1, ge=1, le=100)
    text: str = Field(max_length=10000)


class Block(BaseModel):
    model_config = ConfigDict(extra='forbid')
    page: int = Field(ge=1, le=20)
    kind: Literal['heading', 'paragraph', 'list', 'table', 'math']
    text: str = Field(max_length=100000)
    box: Box
    cells: list[Cell] = Field(default_factory=list, max_length=10000)

    @model_validator(mode='after')
    def no_overlap(self):
        if sum(cell.rowspan*cell.colspan for cell in self.cells)>20000:
            raise ValueError('Table occupied area exceeds limit')
        if self.cells and max(cell.row+cell.rowspan for cell in self.cells)*max(cell.column+cell.colspan for cell in self.cells)>20000:
            raise ValueError('Table grid dimensions exceed limit')
        occupied = set()
        for cell in self.cells:
            for row in range(cell.row, cell.row+cell.rowspan):
                for column in range(cell.column, cell.column+cell.colspan):
                    if (row, column) in occupied:
                        raise ValueError('Overlapping table cells')
                    occupied.add((row, column))
        return self


class Layout(BaseModel):
    model_config = ConfigDict(extra='forbid')
    blocks: list[Block] = Field(max_length=5000)
    warnings: list[str] = Field(default_factory=list, max_length=100)


