# Implementation and release status

Updated 18 November 2026. The missing product workflows below now have implementations. This is still an unverified release candidate: source completion is distinct from passing device, native-library and cloud integration tests.

## Offline mobile workflows

| Area | Implemented |
|---|---|
| Composer | Multi-document range import, selection, reorder, rotate, duplicate, remove, blank insertion, scanned-page insertion and export |
| Structural tools | Extract/remove pages; semicolon-separated split groups; split every N pages and burst |
| Security and metadata | AES-256 QPDF encryption with separate user/owner passwords and printing/extraction permissions; decryption; metadata inspection; Info/XMP/page-thumbnail stripping; removal of document actions and embedded-file name trees |
| Crop | Point-margin trim and rectangle crop; rotated-page coordinate mapping. Crop is explicitly distinguished from permanent redaction |
| Compression | Lossless stream optimization; DPI/JPEG raster compression; bounded attempts to reach a 2 MB target |
| Viewer | Rendering outside the UI isolate; visible zoom tiles with a bounded render queue/cache; all-page text search, highlighted search results and selectable extracted text |
| Editing | Highlight, underline, strikeout, freehand ink, positioned text, typed and securely saved handwritten signatures; editable AcroForm text/choice/button fields; undo via copies |
| Redaction | Rectangle redaction with fresh raster-only output, processing one page at a time before QPDF composition. Cropping a page with pending redactions is blocked to avoid incorrect box placement |
| Images | PDF to PNG/JPEG/WebP/TIFF at 72/150/300 DPI; image and multi-frame TIFF import to A4/Letter/image-sized PDF with margins, EXIF orientation correction and fresh metadata-free image objects |
| Scanner and OCR | Android ML Kit and iOS VisionKit scanning; local image OCR exposed as a tool |
| Recipes | Reorderable SQLite recipes chaining scan, optimize, metadata scrub, compression, cloud OCR, PDF/A and burst; per-run cloud consent and deletion after cloud steps |
| Incoming documents | Android content-intent imports and iOS Open In/document-type handling, UUID filenames and bounded private copies |
| Background transfers | Native background uploader/downloader, persistent transfer tracking, saved job list and dispatch/status recovery after reopening the app |
| Identity | Non-exportable P-256 signing keys in Android hardware-backed Keystore or iOS Secure Enclave; signature challenge registration/refresh; session-token versioning and revocation |

## Cloud conversions

- Digital text is reconstructed in XY-cut reading order with repeated margin removal. Hybrid pages retain original vector text and mask it before raster-region AI transcription. Raster regions pass through deskew, bilateral filtering and strip-wise Sauvola thresholding.
- Safe inline and ordinary stylesheet CSS are preserved for HTML conversion; remote resources and unsupported CSS rules are removed.
- Structured layout feeds TXT/Markdown/JSON/XML/HTML, editable DOCX, native XLSX/CSV tables and editable PPTX text/tables. A facsimile slide mode remains available. Math blocks can become editable Office Math through sandboxed Pandoc.
- Conservative numeric typing protects identifiers; spreadsheet formula injection protection and subtotal/tax/total checks are integrated. Layout schema validation bounds table grids before allocation.
- Office outputs are rendered back to PDF in the heavy worker for SSIM/page-count QA; measured reports are returned to the gateway and retained with the owned job.
- SVG export remains vector-based. DXF exports lines, rectangles, text and curve control polygons. DWG uses a real LibreDWG subprocess; it is not a renamed DXF.
- EPUB uses Pandoc. MOBI/AZW3 use Calibre. Legacy DOC/XLS/PPT imports use bounded OLE preflight, reject macros/embedded objects/external resources and run LibreOffice inside filesystem/network isolation.
- OCR exposes language and PDF/A-1b/2b choices. Sinhala and Tamil language packs are included in the heavy image. LaTeX input is routed to sandboxed Pandoc/Typst.
- Flattening uses QPDF appearances/content flattening rather than unnecessarily rasterizing every page.

## Reliability and isolation

Job claims use renewable leases, attempt counters and completion fencing. Stale jobs are recovered by the sweeper and terminal failures release active quotas. A stale worker cannot publish over a newer claim. Redis Pub/Sub drives SSE wakeups, while Postgres snapshots remain authoritative. Explicit purge errors are checked rather than silently treated as deletion success.

CLI subprocesses receive a restricted environment, CPU/file/descriptor limits, filesystem and network namespaces, a private job directory and process-group cleanup. Bubblewrap exposes system binaries/fonts and the current job directory; it does not expose the service directory, other jobs or the parent's proc namespace. LibreOffice uses a private macro-restricted profile. Unsupported sandbox hosts fail closed.

## Remaining release gates and inherent limits

1. **Dependency resolution and full builds are blocked in this environment.** Flutter plugins and the complete Python package graph cannot be downloaded. QPDF/PDFium target SDKs are absent. Docker's daemon is unavailable. iOS compilation needs macOS/Xcode. No device or container execution is claimed.
2. Run native integration/forensic tests for annotations, forms, rotated/cropped pages, redaction, signatures and 100+ page memory use. Public-header ABI checks passed; the native implementation has not compiled against the real SDKs here.
3. Run real Postgres/Redis/R2 tests for concurrent quotas, nonce replay, lease recovery, delete/completion races, purge retries and transfer recovery. Apply all SQL migrations before starting the new code.
4. Build the heavy image and smoke-test every external converter. Its pinned LibreDWG source build, Calibre, namespaces, Chromium sandbox and Office round trips remain unverified. Some managed hosts prohibit the required namespaces.
5. Measure conversion fidelity on representative documents. Reconstructed Office layouts, inferred table topology, deskewed citations and CAD curve approximations need review. PDF cannot recover missing authoring semantics. Visual signatures do not cryptographically sign a document; certificate signing is not implemented.
6. App lock and protected keys do not encrypt every document/SQLite file at rest. Hardware signing requires a supported physical device and is not remote attestation. Dart-managed password strings cannot be guaranteed to be erased from every VM copy; mutable native buffers are wiped and passwords are not persisted or logged.
7. The 60fps target and 70/30 execution ratio have not been measured. Background execution remains subject to OS cancellation and signed-URL expiry. Reopening a saved job reconciles completed uploads; an expired upload must be started again.
8. No cloud resources have been deployed. Provider quotas, billing eligibility, AI data terms and delayed lifecycle deletion prevent an unconditional $0/month or exact one-hour deletion guarantee. Scheduled purge must be deployed and monitored.
9. Apple SF font binaries are not redistributed to Android. Android uses bundled licensed Roboto. Resolve reproducible dependency lockfiles, SBOMs, vulnerability checks, store signing and privacy disclosures before distribution.

See VERIFICATION.md for the exact checks that ran. Do not equate this inventory with a production certification.
