"""Conservative numeric typing and explicit arithmetic evidence."""
from decimal import Decimal, InvalidOperation
import re


NUMBER = re.compile(r'^([+-]?)(?:([$€£])\s*)?((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)$')


def number(value) -> Decimal | None:
    if value is None:
        return None
    text = str(value).strip()
    negative = text.startswith('(') and text.endswith(')')
    if negative:
        text = text[1:-1]
    match = NUMBER.fullmatch(text)
    if not match:
        return None
    # Leading zero identifiers (postcodes, account numbers) must remain strings.
    digits = match[3].replace(',', '')
    if len(digits) > 1 and digits[0] == '0' and digits[1] != '.':
        return None
    try:
        result = Decimal(match[1]+digits)
        return -result if negative else result
    except InvalidOperation:
        return None


def check_totals(rows: list[list]) -> dict:
    labels = {}
    for index, row in enumerate(rows):
        if not row:
            continue
        label = re.sub(r'[^a-z]', '', str(row[0]).lower())
        kind = 'subtotal' if label in {'subtotal','nettotal'} else 'tax' if label in {'tax','gst','vat'} else 'total' if label in {'total','grandtotal','amountdue'} else None
        if kind:
            values = [(column, number(value)) for column, value in enumerate(row[1:], 1)]
            labels[kind] = (index, {column: value for column, value in values if value is not None})
    checks = []
    if all(key in labels for key in ('subtotal','tax','total')):
        for column in set(labels['subtotal'][1]) & set(labels['tax'][1]) & set(labels['total'][1]):
            difference = labels['subtotal'][1][column]+labels['tax'][1][column]-labels['total'][1][column]
            checks.append({'column': column+1, 'difference': str(difference), 'passed': abs(difference) <= Decimal('.02')})
    return {'checks': checks, 'status': 'not_applicable' if not checks else 'passed' if all(check['passed'] for check in checks) else 'review_required'}
