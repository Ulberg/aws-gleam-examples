# lambda-s3

Directly-invoked AWS Lambda written in Gleam that stores each
invocation payload as an object in S3. Invoke it with any payload and
the raw bytes land at `s3://$BUCKET_NAME/events/<request-id>.json`;
the handler replies `{"stored":"<key>"}`.

Runs the [aws-gleam](https://github.com/Ulberg/aws-gleam) SDK on
Lambda via a container image — the SDK targets Erlang/BEAM, which
Lambda's first-party runtimes don't ship, so the BEAM rides inside the
image. The Runtime API polling loop lives in `aws_gleam_runtime`
(`import aws/lambda`), so the example itself is just a handler:

```gleam
pub fn main() {
  let assert Ok(client) = s3.new_with_auto_region()
  let assert Ok(bucket) = get_env("BUCKET_NAME")
  lambda.start(fn(payload, ctx) { store(client, bucket, payload, ctx) })
}
```

> Supersedes the [`lambda-dynamodb-sqs/`](../lambda-dynamodb-sqs/)
> example, which hand-rolled the same Runtime API loop locally
> (~250 LOC in `src/lambda.gleam`) before `aws/lambda` shipped in
> `aws_gleam_runtime`.

## Architecture

```
aws lambda invoke --payload '{...}' ─── Lambda function
                                              │
                                              ↓
                                  PutObject events/<request-id>.json
                                              │
                                              ↓
                                          S3 bucket
```

- **S3 bucket** — SSE-AES256, public access blocked, `force_destroy`.
- **Lambda function** — `linux/arm64` container image based on
  `ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine`, pulled from a
  per-deploy ECR repo. Directly invoked — no SQS trigger, no event
  source mapping.

## Layout

```
lambda-s3/
├── gleam.toml              hex deps: aws_gleam_runtime + _s3
├── src/
│   ├── lambda_s3.gleam     handler: PutObject the payload, reply with the key
│   └── lambda_s3_ffi.erl   os:getenv shim (binary <-> charlist)
├── Dockerfile              container image (gleam-lang base, deps + export)
├── build.sh                docker build + ECR push + tofu apply
├── run.sh                  invoke once + fetch the stored object
└── infra/                  OpenTofu: S3 + ECR + Lambda + IAM
```

## Prereqs

- Docker (with `buildx`)
- OpenTofu (or Terraform — the module is plain HCL)
- AWS CLI v2 + credentials in env (`eval "$(aws configure
  export-credentials --format env)"`)
- **aws-gleam SDK ≥ 1.2.0** — `aws/lambda` (the Runtime API loop)
  ships in `aws_gleam_runtime` as of 1.2.0; there's no standalone
  `aws_gleam_lambda` package. The Docker build pulls it from hex.

## One-time setup

```sh
eval "$(aws configure export-credentials --format env)"
export AWS_REGION=us-east-1

# Bucket names are globally unique — pin to your account.
cd lambda-s3/infra
cat > terraform.tfvars <<EOF
bucket_name = "aws-gleam-lambda-s3-$(aws sts get-caller-identity --query Account --output text)-us-east-1"
EOF
cd ..
```

## Deploy

```sh
cd lambda-s3
./build.sh
```

`build.sh` creates the ECR repo, builds + pushes the arm64 image, then
`tofu apply`s the bucket + Lambda (pinned to the pushed image digest,
so re-running rolls the function forward). First run takes ~3-5 min
(base image pull + `gleam deps download` + OTP shipment build);
subsequent runs hit Docker's layer cache.

## Invoke + verify

```sh
./run.sh                      # default payload
./run.sh '{"any":"json"}'     # custom payload
```

`run.sh` invokes the function, prints the `{"stored":"<key>"}`
response, and fetches that object back out of S3 so you can see the
round-trip. By hand:

```sh
aws lambda invoke --function-name aws-gleam-lambda-s3 \
  --cli-binary-format raw-in-base64-out \
  --payload '{"hello":"world"}' /dev/stdout

aws s3 ls s3://<bucket>/events/
aws logs tail /aws/lambda/aws-gleam-lambda-s3 --follow --since 1m
```

## What this shows about running aws-gleam on Lambda

1. **Erlang/BEAM on Lambda needs a container image.** `provided.al2023`
   ships no language runtime; the `gleam:…-erlang-alpine` base pairs a
   matching Gleam + Erlang so the bytecode compiled inside loads at
   runtime.
2. **The Runtime API loop is a package now.** `import aws/lambda` +
   `lambda.start(handler)` replaces the loop the lambda-dynamodb-sqs
   example carried locally. The handler is a plain
   `fn(BitArray, Context) -> Result(BitArray, InvocationError)`.
3. **Same credentials chain as anywhere.** `s3.new_with_auto_region()`
   reads `AWS_REGION` and resolves creds env-first — exactly what the
   Lambda execution environment populates. Built once in `main`,
   reused across warm invocations.
4. **Streaming bodies.** The payload becomes a `streaming` blob via
   `streaming.from_bit_array` and is handed straight to `put_object`.

## Tear down

```sh
cd lambda-s3/infra
tofu destroy -auto-approve
```

`force_destroy = true` on the bucket removes stored objects with it;
the ECR images go with the repo.

## Known limitations

- **Cold start** ~3-5 s (BEAM startup). Warm invocations reuse the
  cached client, so the AWS-call portion is sub-100ms.
- **arm64 only** for the build. Switch the Dockerfile `--platform` and
  the Terraform `architectures = ["arm64"]` together for x86_64.
- **No payload validation.** Whatever bytes you invoke with are stored
  verbatim under a `.json` key — the handler doesn't parse or check
  them.
