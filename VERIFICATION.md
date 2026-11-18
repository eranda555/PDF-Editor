# Verification record

Environment: Windows, Python 3.12.10, Flutter 3.47.9, Dart 3.13.7. Repository created in the supplied `pdf-editor` workspace.

## Passed

- **17 new pipeline cases**: column reading order, spanning headers, repeated margin removal, word grouping, numeric/currency preservation, formula/identifier rejection, arithmetic tolerances, bounded table topology, conversion-pair and OCR-option validation.
- **Compiled native public-header ABI check**: real bridge header, rectangle size/offsets and render/markup/tile function signatures compiled and executed with MSVC. This does not validate the native implementation or SDK linkage.

- **10 Python authentication/dispatch cases**: real P-256 DER and Ed25519 signing/verification and tampering rejection; JWT issuer, audience and 900-second lifetime; random hashed refresh tokens; malformed key rejection; strict request-schema validation; weak-secret rejection; body-bound HMAC; stale and altered dispatch rejection before nonce-store access.
- **7 Python file-validation cases**: external OOXML relationship rejection; ZIP traversal rejection; image signature verification; binary text rejection; percent-encoded external relationship rejection; a structurally acceptable ZIP package; exact byte-length mismatch rejection.
- **11 Dart page-range cases**: ascending and descending ranges, `end`, duplicate selection, whitespace normalization, and seven malformed/out-of-bounds inputs.
- Python files parsed/byte-compiled, JSON/XML parsed by `scripts/verify_sources.py`.
- Dart formatter parsed application and test source. Available analyzer findings about braces and unnecessary null assertions were corrected.

The Python tests above use `unittest` and are also discoverable by pytest. They do not use simulated crypto or mocked service responses. Cached wheels supplied the Python dependencies for these selected tests; no live provider calls were made.

## Blocked or not run

| Check | Observed blocker |
|---|---|
| Full pytest, including generated-PDF validation | pytest, pypdf and other full dependency-set packages were not available; network package downloads failed DNS resolution |
| Complete Flutter analysis | Pub dependency resolution failed because mobile plugins were absent from the local cache. Partial analysis against cached packages is not a passing Flutter analysis result |
| Android/iOS builds | QPDF/PDFium target libraries absent; iOS requires macOS/Xcode |
| Native C++ build | CMake found MSVC and stopped at missing QPDF 12.4 package configuration; PDFium was also not provided |
| Docker image builds/runtime | Docker daemon pipe unavailable |
| Postgres queue and API integration | No configured Neon/Postgres, Upstash Redis REST or R2 credentials/services |
| HMAC replay storage behavior | Pre-store rejection tested; valid nonce reservation/replay requires real Redis REST |
| Gemini structured-output calls | No API key; AI disabled by default |
| Scanner, screen protection and app lock | No attached Android/iOS device or emulator test |
| Redaction forensic verification and large-document memory | Native libraries/device runtime unavailable |
| Conversion corpus and SSIM accuracy | Runtime engines and representative corpus unavailable |
| Cloud cost and expiry behavior | Nothing deployed; no cost or retention SLA established |

## Re-run with dependencies installed

From the root:

```sh
python -m pip install -r backend-cloudrun/requirements.txt
python scripts/verify_sources.py
python -m pytest
```

In `mobile`:

```sh
flutter pub get
flutter analyze
dart test/page_range_test.dart
```

Then build and test native libraries and the containers using the setup in `README.md`. A production release requires the additional evidence listed in `IMPLEMENTATION_STATUS.md`.

Latest complete Flutter CLI analysis ran after the SDK copy was repaired, but could not pass because required packages were unavailable. The remaining unresolved-type diagnostics include Drift and mobile plugins. Owned-source formatting, brace/null-safety lint fixes and asynchronous UI context guards were corrected; this is not a passing full analysis result.
