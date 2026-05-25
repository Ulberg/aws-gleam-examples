# lambda-dynamodb-sqs

> **Deprecated — superseded by [`lambda-s3/`](../lambda-s3/).** That
> example runs Gleam on Lambda via the first-party `aws_gleam_lambda`
> package (`import aws/lambda` + `lambda.start`) instead of the ~250
> LOC Runtime API loop hand-rolled here in `src/lambda.gleam`. This
> example is kept for reference — the hand-rolled loop is a useful
> read if you want to see what the package now does for you — but it's
> not recommended for new work.

SQS-triggered AWS Lambda function written in Gleam. Each incoming
SQS message is parsed as JSON and landed as a row in a DynamoDB
table. Per-message failures surface as partial-batch failures via
the `ReportBatchItemFailures` response mode so Lambda only
redrives the failing messages.

Demonstrates the aws-gleam SDK on Lambda via container image
deploy — the SDK targets Erlang/BEAM, which Lambda's first-party
runtimes don't support, so we ship the BEAM inside a container
image. Pattern was informed by reading
[`glambda`](https://github.com/ryanmiville/glambda)'s typed event
and `Handler` shape (glambda itself targets the Node.js runtime
via the JS target — incompatible with the aws-gleam SDK which is
Erlang-only).

## Architecture

```
client → aws sqs send-message → SQS queue ─── trigger ─── Lambda function
                                                    │           │
                                                    │           ↓
                                                    │     parse JSON body
                                                    │           │
                                                    │           ↓
                                                    │     DynamoDB PutItem
                                                    │           │
                                                    ◄ delete on success
```

- **DynamoDB table** — pay-per-request, hash key `user_id`.
- **SQS queue** — 1-day retention, 60s visibility timeout.
- **Lambda function** — `linux/arm64` container image based on
  `ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine`, fetched from a
  per-deploy ECR repository. Event source mapping batches 10
  records per invocation.

## Layout

```
lambda-dynamodb-sqs/
├── gleam.toml              hex deps: aws_gleam_runtime + _dynamodb + _sqs
├── src/
│   ├── lambda.gleam        typed event records + handler
│   │                       dispatcher + Runtime API polling loop
│   │                       (glambda-inspired, Erlang-target)
│   └── lambda_dynamodb_sqs.gleam   handler: parse, PutItem
├── Dockerfile              container image (single stage,
│                           gleam-lang base, deps download + export inside)
├── build.sh                docker build + ECR push + tofu apply
└── infra/                  OpenTofu: DynamoDB + SQS + Lambda + IAM
```

## Prereqs

- Docker (with `buildx`)
- OpenTofu (or Terraform — module is plain HCL)
- AWS CLI v2 + credentials in env (`eval "$(aws configure
  export-credentials --format env)"`)

## Deploy + invoke

```sh
eval "$(aws configure export-credentials --format env)"
export AWS_REGION=us-east-1
./build.sh
```

`build.sh` prints the exact `aws sqs send-message` command after
the deploy completes. The flow:

```sh
# Send a message:
aws sqs send-message --queue-url "<from outputs>" \
  --message-body '{"user_id":"u-1","data":"hello"}'

# Watch the Lambda pick it up:
aws logs tail "/aws/lambda/aws-gleam-lambda-dynamodb-sqs" --follow --since 1m

# Verify the row landed:
aws dynamodb scan --table-name "aws-gleam-lambda-dynamodb-sqs-users" --max-items 5
```

## What this shows about running aws-gleam on Lambda

1. **Erlang/BEAM on Lambda needs a container image.** `provided.al2023`
   has no language runtime — the `gleam:v1.16.0-erlang-alpine` base
   image ships a matching Gleam + Erlang pair, so the BEAM bytecode
   compiled inside is guaranteed to load at runtime.
2. **The Lambda Runtime API loop is hand-rolled** (`src/lambda.gleam`)
   because there's no Erlang-target glambda equivalent yet. ~250
   LOC, would lift cleanly into its own `aws_gleam_lambda` hex
   package once the patterns stabilize.
3. **Typed events**: `SqsEvent` / `SqsRecord` / `Context` model
   the Lambda contract; the dispatcher (`lambda.sqs_handler`)
   decodes the raw payload into the typed record before calling
   the user handler. Same shape as glambda, sync return instead of
   `Promise(_)`.
4. **Partial-batch failures**: the handler returns
   `Option(SqsBatchResponse)`. `None` = all-clean; `Some(ids)` =
   redrive these message IDs only. The event source mapping is
   configured with `function_response_types =
   ["ReportBatchItemFailures"]` to honour this.

## Known limitations

- **Cold start** is ~3-5 s — BEAM startup + 2 service modules. SDK
  caches credentials per-invocation in our `runtime.invoke`, so
  warm invocations are sub-100ms for the AWS-call portion.
- **arm64 only** for the build. Apple-silicon dev hosts build
  natively, no QEMU emulation. Lambda arm64 is ~20% cheaper. Switch
  the Dockerfile's `--platform` + the Terraform
  `architectures = ["arm64"]` together if you want x86_64.
- **No DLQ** on the SQS queue. After max receive count Lambda
  stops redriving; messages get discarded silently. Add a DLQ in
  `infra/main.tf` for anything beyond demo use.
