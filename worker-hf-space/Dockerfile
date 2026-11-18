FROM rust:1.85-bookworm AS typst
RUN cargo install typst-cli --locked --version 0.13.1
FROM debian:bookworm-slim AS libredwg
RUN apt-get update && apt-get install -y --no-install-recommends build-essential autoconf automake libtool git ca-certificates pkg-config libpcre2-dev && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch 0.13.4 https://github.com/LibreDWG/libredwg.git /build
WORKDIR /build
RUN ./autogen.sh && ./configure --disable-shared && make -j2 && make install
FROM python:3.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 HOME=/tmp PLAYWRIGHT_BROWSERS_PATH=/opt/browsers OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
RUN apt-get update && apt-get install -y --no-install-recommends libreoffice-writer libreoffice-calc libreoffice-impress ghostscript tesseract-ocr tesseract-ocr-eng tesseract-ocr-sin tesseract-ocr-tam pandoc qpdf poppler-utils calibre libpcre2-8-0 fonts-liberation fonts-noto-core libglib2.0-0 libgl1 ca-certificates util-linux bubblewrap && rm -rf /var/lib/apt/lists/*
COPY --from=typst /usr/local/cargo/bin/typst /usr/local/bin/typst
COPY --from=libredwg /usr/local/bin/dxf2dwg /usr/local/bin/dxf2dwg
WORKDIR /service
COPY backend-cloudrun/requirements.txt /service/backend-cloudrun/requirements.txt
COPY worker-hf-space/requirements.txt /service/worker-hf-space/requirements.txt
RUN pip install --no-cache-dir -r /service/worker-hf-space/requirements.txt && playwright install --with-deps chromium && useradd --uid 1000 --create-home appuser && chmod -R a+rX /opt/browsers
COPY backend-cloudrun/app /service/app
COPY worker-hf-space/app /service/worker_app
USER 1000:1000
EXPOSE 7860
CMD ["uvicorn", "worker_app.main:app", "--host", "0.0.0.0", "--port", "7860", "--no-access-log", "--limit-concurrency", "2"]
