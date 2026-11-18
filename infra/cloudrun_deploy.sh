#!/usr/bin/env bash
set -euo pipefail
: "${GOOGLE_CLOUD_PROJECT:?Set project id}"
: "${REGION:=us-central1}"
: "${IMAGE:?Set a built gateway image URL}"
: "${SECRET_ENV_FILE:?Set a Cloud Run environment YAML file path}"
# Deployment requires an enabled billing account. Free-tier usage is conditional.
gcloud run deploy pdf-gateway --project "$GOOGLE_CLOUD_PROJECT" --region "$REGION" \
  --image "$IMAGE" --min-instances=0 --max-instances=1 --memory=1Gi \
  --cpu=1 --concurrency=8 --timeout=300 --port=8080 --allow-unauthenticated \
  --env-vars-file "$SECRET_ENV_FILE" --no-cpu-boost
# A separate request-scoped queue consumer keeps API capacity available.
gcloud run deploy pdf-queue-consumer --project "$GOOGLE_CLOUD_PROJECT" --region "$REGION" \
  --image "$IMAGE" --min-instances=0 --max-instances=1 --memory=1Gi \
  --cpu=1 --concurrency=1 --timeout=900 --port=8080 --allow-unauthenticated \
  --env-vars-file "$SECRET_ENV_FILE" --no-cpu-boost
echo 'Configure the scheduled Worker with gateway and consumer URLs and INTERNAL_TOKEN.'
echo 'Cloud Run manages its writable filesystem; Docker read_only applies to self-hosted deployments.'
