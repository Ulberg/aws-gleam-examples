# aws-gleam-examples

Deployable examples for the [aws-gleam](https://github.com/Ulberg/aws-gleam) SDK. Each is standalone, with its own infra.

| Example | What |
|---|---|
| [`lambda-s3/`](./lambda-s3/) | Lambda that stores each invocation payload in S3. |
| [`fargate-s3/`](./fargate-s3/) | Writer + reader Fargate tasks — an S3 + SQS round-trip. |

## Dependencies

One hex package per AWS service, plus `aws_gleam_runtime`, pinned to the major:

```toml
aws_gleam_runtime = ">= 1.4.0 and < 2.0.0"
aws_gleam_s3      = ">= 1.4.0 and < 2.0.0"
```

All `aws_gleam_*` move in lock-step under one tag, so one constraint fits every dep. Minor/patch auto-resolve (`gleam deps update`); a `2.0.0` needs an explicit bump.

Each example's README has its run, deploy, and teardown commands.
