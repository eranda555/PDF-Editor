# Third-party notices

This file records intended dependency boundaries, not a final audited SBOM. Retain the complete license and notice files accompanying the exact versions built for release.

| Component | Intended license boundary |
|---|---|
| Flutter/Dart | BSD-style licenses; include framework/runtime notices |
| QPDF | Apache-2.0; include notices and crypto/compression dependency licenses |
| PDFium | BSD-style license plus bundled third-party notices; audit the actual build flags and dependencies |
| Roboto | Apache-2.0; included license is in `mobile/assets/fonts/roboto_license.txt` |
| pypdf/pypdfium2/pdfminer.six/pdfplumber | Permissive Python/native wrappers; retain exact package notices |
| FastAPI/Pydantic/Psycopg/Procrastinate and other dependencies | Preserve each exact package's licenses in the resolved dependency inventory |
| Ghostscript | Copyleft/commercial licensing applies to distributing the CLI/container; process isolation is not a general exemption |
| LibreOffice | MPL/LGPL and bundled-component obligations apply to distributing the worker |
| OCRmyPDF | MPL-2.0 plus Tesseract/Ghostscript and other runtime dependencies |
| Pandoc/Poppler | Copyleft runtime tools, invoked as subprocesses; preserve applicable distribution obligations |
| Chromium/Playwright | Chromium third-party notices and Playwright license; retain runtime notices |

No Apple SF font binaries are distributed. iOS requests the OS-provided typography; Android ships Roboto. No MuPDF/PyMuPDF dependency is included. The in-process `pdf2docx` route is excluded to avoid its usual PyMuPDF dependency.

Do not describe the complete Docker images as Apache/BSD/MIT-only. They include separately licensed CLI programs. Before shipping closed-source mobile binaries, audit the linked native libraries, their transitive dependencies and the complete package graph.

The expanded heavy worker also runs Calibre and LibreDWG as separate GPL-licensed CLI programs. Bubblewrap provides additional Linux isolation. Include their distribution obligations in the final container license audit. Mobile background_downloader and flutter_image_compress retain their package and native dependency notices.
