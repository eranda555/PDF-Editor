FROM python:3.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 HOME=/tmp OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
RUN apt-get update && apt-get install -y --no-install-recommends poppler-utils qpdf pandoc util-linux bubblewrap libglib2.0-0 libgl1 fonts-liberation fonts-noto-core ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /service
COPY backend-cloudrun/requirements.txt /service/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt && useradd --uid 1000 --create-home appuser
COPY backend-cloudrun/app /service/app
COPY backend-cloudrun/migrations /service/migrations
USER 1000:1000
EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log", "--limit-concurrency", "20", "--timeout-keep-alive", "5"]
