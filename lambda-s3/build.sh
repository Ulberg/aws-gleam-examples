#!/bin/sh
# Build + push the container image, then tofu apply the Lambda
# function so it picks up the new image digest.
#
# Set `SKIP_INFRA=1` to stop after the push (e.g. for `docker run`
# locally to debug the image).
#
# Prereqs: docker (with buildx), tofu (or terraform), AWS CLI v2,
# AWS credentials in env vars (`eval "$(aws configure
# export-credentials --format env)"`), and infra/terraform.tfvars
# with a globally-unique `bucket_name` (see README "one-time setup").

set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

IMAGE_TAG="${IMAGE_TAG:-latest}"

echo "→ ensuring ECR repo exists"
( cd "$HERE/infra" && tofu init -upgrade=false >/dev/null && \
  tofu apply -auto-approve -target=aws_ecr_repository.lambda >/dev/null )

REPO_URL=$( cd "$HERE/infra" && tofu output -raw ecr_repo_url )
# Derive the login region from the repo URL itself
# (<acct>.dkr.ecr.<region>.amazonaws.com/<repo>). The `region` output isn't
# materialised by the targeted apply above, so reading it here would fall
# back to us-east-1 and mismatch the repo when region != us-east-1.
REGION=$( printf '%s\n' "$REPO_URL" | sed -E 's/.*\.dkr\.ecr\.([^.]+)\.amazonaws\.com.*/\1/' )

echo "→ building container image for linux/arm64"
docker buildx build \
  --platform linux/arm64 \
  --provenance=false \
  --load \
  -t "${REPO_URL}:${IMAGE_TAG}" \
  -f "$HERE/Dockerfile" \
  "$HERE"

echo "→ docker login to ECR ($REGION)"
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$REPO_URL"

echo "→ docker push"
docker push "${REPO_URL}:${IMAGE_TAG}"

if [ "${SKIP_INFRA:-0}" = "1" ]; then
  echo "done → image pushed; skipping tofu apply (SKIP_INFRA=1)"
  exit 0
fi

echo "→ tofu apply (Lambda rolls forward to new image digest)"
( cd "$HERE/infra" && tofu apply -auto-approve )

echo
FN=$( cd "$HERE/infra" && tofu output -raw lambda_function_name )
BUCKET=$( cd "$HERE/infra" && tofu output -raw bucket_name )
LOG=$( cd "$HERE/infra" && tofu output -raw log_group )

echo "done."
echo
echo "Try:"
echo "  ./run.sh '{\"hello\":\"world\"}'   # invoke + show the stored object"
echo
echo "  # Or by hand:"
echo "  aws lambda invoke --function-name '$FN' \\"
echo "    --cli-binary-format raw-in-base64-out \\"
echo "    --payload '{\"hello\":\"world\"}' /dev/stdout"
echo
echo "  # Watch the logs:"
echo "  aws logs tail '$LOG' --follow --since 1m"
echo
echo "  # List stored objects:"
echo "  aws s3 ls 's3://$BUCKET/events/'"
