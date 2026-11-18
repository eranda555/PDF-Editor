from pathlib import Path


def validate_legacy(path: Path, extension: str):
    import olefile
    if not olefile.isOleFile(path):
        raise ValueError('Legacy Office container signature mismatch')
    with olefile.OleFileIO(path,raise_defects=olefile.DEFECT_INCORRECT) as archive:
        entries=archive.listdir()
        if len(entries)>5000:
            raise ValueError('Legacy Office directory limit exceeded')
        names={entry[0].lower() for entry in entries if entry}
        expected={'doc':{'worddocument'},'xls':{'workbook','book'},'ppt':{'powerpoint document'}}[extension]
        if not names & expected:
            raise ValueError('Legacy Office type mismatch')
        total=0
        for entry in entries:
            label='/'.join(entry).lower()
            if any(token in label for token in ('vba','macros','objectpool','encryptioninfo','encryptedpackage')):
                raise ValueError('Macros, embedded objects and encrypted Office files are forbidden')
            size=archive.get_size(entry);total+=size
            if size>30_000_000 or total>120_000_000:
                raise ValueError('Legacy Office stream expansion limit exceeded')
            data=archive.openstream(entry).read().lower()
            for scheme in ('file://','http://','https://','ftp://'):
                if scheme.encode() in data or scheme.encode('utf-16-le') in data:
                    raise ValueError('External resources in legacy Office are forbidden')
