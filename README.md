# aws-gleam-examples

Real-world deploys consuming the [aws-gleam](https://github.com/Ulberg/aws-gleam)
SDK. Each subdirectory is a standalone example with its own deploy
infra; they share no code.

| Example | What it shows |
|---|---|
| [`fargate-smoke-test/`](./fargate-smoke-test/) | End-to-end smoke test of S3 + SQS from inside two ECS Fargate roles (writer + reader). Validates the credentials chain, SigV4 signing, endpoint resolution, and HTTP transport against live AWS. |

More examples (Lambda via container image, EC2, EKS, etc.) will
land here when there's a working pattern for each. See
[`aws-gleam/docs/lambda-gleam.md`](https://github.com/Ulberg/aws-gleam/blob/main/docs/lambda-gleam.md)
for the three known approaches to deploying Gleam to Lambda; only
one of them lives here today.

## Consuming the SDK

Each example's `gleam.toml` lists exactly the per-service hex
packages it imports, on top of the shared `aws_runtime`:

```toml
[dependencies]
aws_runtime = ">= 0.1.0"
aws_s3      = ">= 0.1.0"
aws_sqs     = ">= 0.1.0"
```

That way, your compile only touches the AWS services you use —
not all 409 the SDK supports. The tree-shaking trick: the SDK
ships one hex package per service, not one mega-package
containing everything.

During the SDK's pre-publish phase, examples use path deps to a
sibling `aws-gleam/` checkout instead of hex version constraints.
Comments in each example's `gleam.toml` explain the flip.

## Pre-publish quickstart (path deps, sibling checkout)

```sh
# Both repos as siblings under one parent directory:
git clone https://github.com/Ulberg/aws-gleam.git
git clone https://github.com/Ulberg/aws-gleam-examples.git
ls
# → aws-gleam/ aws-gleam-examples/

# Deploy the Fargate smoke test:
cd aws-gleam-examples/fargate-smoke-test
eval "$(aws configure export-credentials --format env)"
export AWS_REGION=us-east-1
./build.sh
./run-smoke.sh "hello from fargate"
```

## Post-publish quickstart (hex deps, no sibling needed)

Once the SDK's first version is on hex, the example's
`gleam.toml` becomes:

```toml
aws_runtime = ">= 0.1.0"
aws_s3      = ">= 0.1.0"
aws_sqs     = ">= 0.1.0"
```

and the deploy collapses to:

```sh
git clone https://github.com/Ulberg/aws-gleam-examples.git
cd aws-gleam-examples/fargate-smoke-test
eval "$(aws configure export-credentials --format env)"
export AWS_REGION=us-east-1
./build.sh
```

No sibling checkout, no in-image SDK regen, no atom-table flags.
The Dockerfile collapses to ~5 lines.
