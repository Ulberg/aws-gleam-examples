#!/bin/sh
# Invoke the Lambda once with a JSON payload, print its response, then
# fetch the object it stored in S3 so you can eyeball the round-trip.
# Assumes `./build.sh` has run (image pushed, infra applied) and AWS
# creds are in the current shell.
#
# Usage:
#   ./run.sh                      # default payload
#   ./run.sh '{"any":"json"}'     # custom payload

set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
# Separate var so the JSON's braces don't collide with `${1:-...}`
# brace-matching — an inline default ending in `}}` makes the shell append a
# stray `}` to $1 (e.g. `{"hello":"cloud"}` -> `{"hello":"cloud"}}`).
DEFAULT_PAYLOAD='{"hello":"from aws-gleam lambda-s3"}'
PAYLOAD="${1:-$DEFAULT_PAYLOAD}"

cd "$HERE/infra"
FN=$(tofu output -raw lambda_function_name)
BUCKET=$(tofu output -raw bucket_name)
REGION=$(tofu output -raw region)

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

echo "→ invoking $FN with payload: $PAYLOAD"
aws lambda invoke \
  --function-name "$FN" \
  --region "$REGION" \
  --cli-binary-format raw-in-base64-out \
  --payload "$PAYLOAD" \
  "$OUT" >/dev/null

RESP=$(cat "$OUT")
echo "→ response: $RESP"

# Response is {"stored":"events/<request-id>.json"} — pull the key
# back out and fetch the object the handler just wrote.
KEY=$(printf '%s' "$RESP" | sed -E 's/.*"stored":"([^"]+)".*/\1/')
if [ "$KEY" = "$RESP" ]; then
  echo "could not parse stored key from response: $RESP" >&2
  exit 1
fi

echo "→ fetching s3://$BUCKET/$KEY"
aws s3 cp "s3://$BUCKET/$KEY" - --region "$REGION"
echo
echo "round-trip ok: payload stored at s3://$BUCKET/$KEY"
