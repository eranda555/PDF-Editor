# 100% PDF Suite

Flutter mobile client, a FastAPI gateway, a Postgres JSONB queue, a native QPDF/PDFium bridge, and an isolated conversion worker.

**Status: expanded implementation, not a verified production release.** Source exists for the modules described below. The expanded workflow inventory and remaining verification limits are recorded in IMPLEMENTATION_STATUS.md. Native binaries and cloud credentials are not bundled. Do not deploy sensitive documents until the remaining security and integration checks in [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) are closed.

## What is here

- Mint/coral Flutter design tokens, rounded cards, bundled Apache-licensed Roboto, Apple system typography on iOS, execution badges, app lock and secure token storage.
- Multi-document page composer with range import, selection, drag reorder, rotation, duplication, deletion, blank insertion and QPDF export.
- PDFium page rendering, selectable extracted text, zoom/pan and rectangle redaction that writes a new raster-only document. The original file is retained separately.
- ML Kit Android scanner and VisionKit iOS scanner, image metadata stripping, 2000px image resizing and PDF generation.
- SQLite recipes for stream optimization, document metadata stripping and page bursting.
- Hardware-backed P-256 challenge registration, rotating refresh tokens, short-lived JWTs, ownership-scoped job access, atomic Redis quotas, opaque signed uploads, SSE progress and deletion.
- PDF triage, bounded rasterization, deskew/Sauvola utilities, structured Gemini layout schemas, document/table exporters and isolated Office/HTML/OCR converters.
- Postgres migrations, Procrastinate task consumer, outbox dispatch, explicit expiry sweeper, non-root Dockerfiles and deployment scripts.

Read [CHANGELOG.md](CHANGELOG.md) for the latest implementation work. See [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for exact gaps and fidelity limits; file presence does not imply device or cloud validation.

## Cost and privacy assumptions

There is no unconditional $0/month hosted architecture. Leave `CLOUD_ENABLED=false` and `AI_ENABLED=false` for an offline-first build with no service requests by default. Quotas limit usage, but do not constitute a provider billing cap. Every provider can change free-tier allowances. Cloud Run deployment requires an enabled billing account.

As checked on 17 November 2026:

- [Hugging Face documentation](https://huggingface.co/docs/hub/spaces-overview) says creating a Docker Space requires a paid plan even though CPU Basic has no hourly compute charge. The worker can instead run on your own machine; electricity and hardware are outside hosting cost.
- [Cloudflare lifecycle documentation](https://developers.cloudflare.com/r2/buckets/object-lifecycles/) describes asynchronous deletion, typically within 24 hours of expiry. The one-hour lifecycle policy is a fallback expiry target, not a one-hour deletion guarantee. The scheduled purge service performs explicit deletes; outages can delay it.
- [Apple's font license](https://developer.apple.com/fonts/) restricts redistribution. No Apple font binaries are included. Android uses bundled Roboto; it is not metrically identical to SF Pro.
- [Gemini pricing and data-use terms](https://ai.google.dev/gemini-api/docs/pricing) must be reviewed before enabling AI for private material. Transport encryption is not end-to-end encryption: the conversion service and AI provider must read the document to process it.

The requested `gemini-3.8-flash` and `gemini-3.5-flash-lite` identifiers are configurable defaults. There is no automatic substitution with an older model. Provider availability, quotas and access must be verified with the operator's account.

## Mobile setup

The generated hosts use Flutter 3.47.9 / Dart 3.13.7. Platform support starts at Android API 24 and iOS 15.5; individual plugin requirements may raise these minima after dependency resolution.

```powershell
cd mobile
flutter pub get
flutter analyze
dart test/page_range_test.dart
```

Install QPDF 12.4+ and PDFium for each target architecture before building. `native/CMakeLists.txt` deliberately fails when these real libraries are absent.

Android expects the following per-ABI prefix:

```text
mobile/native/prebuilt/android/arm64-v8a/
  include/fpdfview.h
  include/fpdf_edit.h
  include/fpdf_save.h
  include/fpdf_text.h
  include/qpdf/
  lib/libpdfium.so
  lib/libqpdf.so
  lib/cmake/qpdf/qpdfConfig.cmake
```

Provide this prefix for both supported Android ABIs, `arm64-v8a` and `x86_64`. Gradle packages the CMake-linked QPDF and PDFium libraries and the NDK shared C++ runtime. If QPDF uses shared libjpeg, copy the matching `libjpeg.so` into `mobile/android/app/src/main/jniLibs/<ABI>/`. Use the [QPDF build instructions](https://qpdf.readthedocs.io/en/stable/installation.html) and [PDFium build instructions](https://pdfium.googlesource.com/pdfium/) to obtain Android binaries.

On macOS, build `PDFium.xcframework` and `QPDF.xcframework` into `mobile/native/prebuilt/ios/`, with public headers exported. The local podspec links them. Run `flutter pub get`, then `pod install` inside `mobile/ios`. The CocoaPods integration and current Flutter-generated Swift Package Manager project need validation together on Xcode; Windows cannot validate iOS linkage.

```powershell
flutter run --dart-define=PDF_API_URL=https://your-gateway.example
```

Omit `PDF_API_URL` to leave cloud UI disabled. Android release signing reads `PDF_SIGNING_*` environment variables; it never falls back to a debug key. Configure your own signing identity before distributing either platform.

## Backend setup

From the repository root, use Python 3.12:

```powershell
py -3.12 -m venv .venv
.venv\Scripts\python -m pip install -r backend-cloudrun/requirements.txt
Copy-Item infra/.env.example .env
```

Fill in real provider credentials and independent random secrets. `.env` is ignored. Register only bucket-scoped R2 credentials. Do not put secrets in mobile assets or `--dart-define` values.

```powershell
cd backend-cloudrun
..\.venv\Scripts\python manage.py
..\.venv\Scripts\python -m uvicorn app.main:app --port 8080 --no-access-log
```

Run the consumer in another terminal, with the same working directory and configuration:

```powershell
..\.venv\Scripts\python -m app.queue.procrastinate_app
```

This Windows command runs the Python consumer, but external converters require Linux containers. Containers are built with the **repository root** as context:

```sh
docker build -f backend-cloudrun/Dockerfile -t pdf-gateway .
docker build -f worker-hf-space/Dockerfile -t pdf-heavy .
docker compose -f infra/compose.yaml up --build
```

Compose uses your configured Postgres, Redis REST and R2 services; it does not create provider accounts. Set `WORKER_URL` to the heavy service reachable from the queue. For self-hosting, use HTTPS or a private TLS proxy between services. Heavy-worker configuration intentionally omits database, JWT and R2 write secrets.

Linux subprocesses default to Bubblewrap filesystem/network namespaces and `prlimit`, with no inherited provider secrets, a per-job profile, timeouts and process-group cleanup. User/network namespaces and the Chromium sandbox must work in the target host. Conversions fail closed if unsupported; neither HF nor Cloud Run is assumed to permit these namespaces. Do not disable the sandbox to make an untested host appear compatible.

The API body limit is 64 KiB; file bodies go directly to signed R2 PUT URLs. Dispatches are validated by the worker before parsing. Resource checks are defense in depth, not a substitute for a container sandbox or native-parser security updates.

## Deployment and expiry

1. Apply the Postgres and Procrastinate schemas using `manage.py`.
2. Apply `infra/r2_lifecycle_policy.json` with `infra/configure_r2.py` and bucket-lifecycle permissions.
3. Deploy the gateway and request-scoped queue consumer with `infra/cloudrun_deploy.sh` after building an image. Remote deployment was not performed in this session.
4. Deploy `infra/expiry-worker/` with `API_URL`, `QUEUE_URL` and the `INTERNAL_TOKEN` secret. Its minute schedule invokes purge separately from long-running conversion requests.
5. Monitor purge failures and quotas. An external schedule is required: a scale-to-zero process cannot promise to wake itself for cleanup.

The API exposes `/v1/auth/challenge`, `/v1/auth/register`, `/v1/auth/refresh`, `/v1/jobs/init`, `/v1/jobs/dispatch`, `GET /v1/jobs/{id}`, `GET /v1/jobs/{id}/stream` and `DELETE /v1/jobs/{id}`. Internal endpoints require a separate bearer secret. There is no wildcard CORS middleware.

## Verification

```sh
python scripts/verify_sources.py
python -m pytest
cd mobile
flutter analyze
dart test/page_range_test.dart
```

Source parsing, 34 Python regression tests and 11 Dart page-range cases passed in the provided workspace. The full `pytest` suite, complete Flutter analysis, native compilation, Docker images and device/cloud integration remain unverified because required dependencies, native SDKs, a running Docker daemon and remote credentials were unavailable. See [VERIFICATION.md](VERIFICATION.md).

## Licensing

Project source is MIT licensed. Third-party dependencies retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). No MuPDF/PyMuPDF code is linked. `pdf2docx` is intentionally omitted because its usual PyMuPDF dependency conflicts with the requested permissive in-process dependency boundary. Ghostscript and Office tools run as separate processes; subprocess separation does not remove distribution and notice obligations.
