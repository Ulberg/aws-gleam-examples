# aws-gleam-examples

Real-world deploys consuming the [aws-gleam](https://github.com/Ulberg/aws-gleam)
SDK. Each subdirectory is a standalone example with its own deploy
infra; they share no code.

| Example | What it shows |
|---|---|
| [`fargate-smoke-test/`](./fargate-smoke-test/) | End-to-end smoke test of S3 + SQS from inside two ECS Fargate roles (writer + reader). Validates the credentials chain, SigV4 signing, endpoint resolution, and HTTP transport against live AWS. |
| [`lambda-dynamodb-sqs/`](./lambda-dynamodb-sqs/) | SQS-triggered Lambda that lands each message into a DynamoDB table. Demonstrates the SDK on Lambda via container image deploy. Typed event + Handler API informed by [glambda](https://github.com/ryanmiville/glambda); partial-batch failure semantics. |

More examples (EC2, EKS, etc.) will land here when there's a
working pattern for each. See [`aws-gleam/docs/lambda-gleam.md`](https://github.com/Ulberg/aws-gleam/blob/main/docs/lambda-gleam.md)
for the three known approaches to deploying Gleam to Lambda; one
of them (container image + Erlang target) is what
`lambda-dynamodb-sqs` uses.

## Consuming the SDK

Each example's `gleam.toml` lists exactly the per-service hex
packages it imports, on top of the shared `aws_gleam_runtime`:

```toml
[dependencies]
aws_gleam_runtime = ">= 0.1.2 and < 0.2.0"
aws_gleam_s3      = ">= 0.1.2 and < 0.2.0"
aws_gleam_sqs     = ">= 0.1.2 and < 0.2.0"
```

Pinned to one minor band. Patch releases pull in automatically
(`0.1.3`, `0.1.4`, …); a `0.2.0` is treated as breaking and
requires an explicit bump per example. The SDK releases under one
tag so every `aws_gleam_*` moves in lock-step — the same
constraint works for every dep.

That way, your compile only touches the AWS services you use —
not all 409 the SDK supports. The tree-shaking trick: the SDK
ships one hex package per service, not one mega-package
containing everything.

During SDK iteration (when you need to test unreleased changes),
swap each example's hex dep for a path dep pointing at a sibling
`aws-gleam/` checkout — e.g.
`aws_gleam_runtime = { path = "../../aws-gleam/runtime" }`. The
example's `gleam.toml` carries a comment explaining the flip.

## Quickstart

```sh
git clone https://github.com/Ulberg/aws-gleam-examples.git
cd aws-gleam-examples/lambda-dynamodb-sqs   # or fargate-smoke-test/

eval "$(aws configure export-credentials --format env)"
export AWS_REGION=us-east-1

./build.sh
```

No sibling checkout, no in-image SDK regen — `gleam deps download`
pulls every `aws_gleam_*` package from hex.pm at the version
pinned in `gleam.toml`. The Dockerfile is just `gleam:erlang-alpine`
+ `gleam deps download && gleam export erlang-shipment`.

## Bumping SDK versions

When a new SDK release lands (`0.1.3`, `0.2.0`, …):

```sh
# 1. Update each example's gleam.toml dep lines manually OR via sed:
sed -i 's/0.1.2/0.1.3/g' */gleam.toml

# 2. Rebuild + redeploy. Path-dep iteration first if a breaking
#    change in 0.2.0 needs the handler updated.
```
