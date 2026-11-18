"""Dependency-free source checks; does not claim runtime or security certification."""
import ast
import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ET


def main():
    root = pathlib.Path(__file__).resolve().parents[1]
    problems = []
    checked = 0
    for module in ('backend-cloudrun', 'worker-hf-space', 'infra', 'scripts'):
        for path in (root/module).rglob('*.py'):
            ast.parse(path.read_text(encoding='utf-8-sig'), filename=str(path))
            checked += 1
    for path in (root/'infra').rglob('*.json'):
        json.loads(path.read_text())
        checked += 1
    for path in (root/'mobile').rglob('*.xml'):
        if 'build' in path.parts or '.dart_tool' in path.parts:
            continue
        ET.parse(path)
        checked += 1
    suffixes = {'.py','.dart','.cpp','.h','.kt','.swift','.kts','.sh'}
    forbidden = re.compile(r'\bTO' + r'DO\b|Unimplemented' + r'Error\s*\(|\bpick' + r'le\b')
    for folder in ('backend-cloudrun','worker-hf-space','mobile','infra'):
        for path in (root/folder).rglob('*'):
            if not path.is_file() or path.suffix not in suffixes or any(part in {'build','.dart_tool','__pycache__'} for part in path.parts):
                continue
            text = path.read_text(encoding='utf-8-sig')
            if forbidden.search(text):
                problems.append(str(path.relative_to(root)))
    if problems:
        print('Forbidden source patterns:', ', '.join(problems))
        return 1
    print(f'Source checks passed: {checked} Python/JSON/XML files parsed; prohibited implementation patterns absent.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
