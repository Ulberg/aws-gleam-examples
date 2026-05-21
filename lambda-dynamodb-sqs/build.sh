#!/bin/sh
# Build + push the container image, then tofu apply the Lambda
# function so it picks up the new image digest.

set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
CONTEXT_ROOT="$(cd "$HERE/../.." && pwd)"

if [ ! -d "$CONTEXT_ROOT/aws-gleam" ]; then
  echo "missing sibling checkout: $CONTEXT_ROOT/aws-gleam" >&2
  echo "clone https://github.com/Ulberg/aws-gleam alongside this repo" >&2
  echo "(or after hex publish, switch path deps to version constraints" >&2
  echo " in gleam.toml — the sibling won't be needed any more)." >&2
  exit 1
fi

IMAGE_TAG="${IMAGE_TAG:-latest}"

echo "→ ensuring ECR repo exists"
( cd "$HERE/infra" && tofu init -upgrade=false >/dev/null && \
  tofu apply -auto-approve -target=aws_ecr_repository.lambda >/dev/null )

REPO_URL=$( cd "$HERE/infra" && tofu output -raw ecr_repo_url )
REGION=$( cd "$HERE/infra" && tofu output -raw region 2>/dev/null || echo us-east-1 )

echo "→ building container image for linux/arm64"
docker buildx build \
  --platform linux/arm64 \
  --provenance=false \
  --load \
  -t "${REPO_URL}:${IMAGE_TAG}" \
  -f "$HERE/Dockerfile" \
  "$CONTEXT_ROOT"

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
QUEUE_URL=$( cd "$HERE/infra" && tofu output -raw queue_url )
TABLE=$( cd "$HERE/infra" && tofu output -raw table_name )
LOG=$( cd "$HERE/infra" && tofu output -raw log_group )

echo "done."
echo
echo "Try:"
echo "  # Send a message via SQS:"
echo "  aws sqs send-message --queue-url '$QUEUE_URL' \\"
echo "    --message-body '{\"user_id\":\"u-1\",\"data\":\"hello from lambda+dynamodb+sqs\"}'"
echo
echo "  # Watch the Lambda pick it up:"
echo "  aws logs tail '$LOG' --follow --since 1m"
echo
echo "  # Verify the row landed in DynamoDB:"
echo "  aws dynamodb scan --table-name '$TABLE' --max-items 5"
