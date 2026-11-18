"""Package source, notices and build configuration without credentials or caches."""
from pathlib import Path
import subprocess
import zipfile


def main():
    root = Path(__file__).resolve().parents[1]
    destination = root/'artifacts/100-percent-pdf-suite-source.zip'
    destination.parent.mkdir(exist_ok=True)
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root).decode().split('\0')
    included = []
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(set(names)):
            if not name:
                continue
            relative = Path(name)
            if relative.name == '.env' or relative.suffix in {'.jks','.keystore'} or any(part in {'__pycache__','.dart_tool','build','.local','.venv','.vscode'} for part in relative.parts):
                continue
            source = root/relative
            if source.is_file():
                archive.write(source, '100-percent-pdf-suite/'+relative.as_posix())
                included.append(relative.as_posix())
    with zipfile.ZipFile(destination) as archive:
        if archive.testzip() is not None:
            raise RuntimeError('Source archive failed CRC verification')
    print(f'Packaged {len(included)} files; {destination.stat().st_size} bytes: {destination}')


if __name__ == '__main__':
    main()
