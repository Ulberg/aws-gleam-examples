# Fargate container image for the aws-gleam Fargate smoke-test
# example.
#
# Build context = the parent directory of this repo (set by
# build.sh: `docker buildx ... ../..` from fargate-smoke-test/).
# That parent directory must contain BOTH this repo
# (aws-gleam-examples) AND the SDK repo (aws-gleam) as sibling
# checkouts, so the example's path deps (aws_runtime, aws_s3,
# aws_sqs at `../../aws-gleam/...`) resolve.
#
# Once the SDK is on hex, this Dockerfile simplifies: no need to
# COPY the SDK in, no need to run the SDK's regen.sh — `gleam
# deps download` will fetch aws_runtime / aws_s3 / aws_sqs from
# hex like any other dependency.

FROM ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine

# Bring both sibling repos into the image. The path deps in
# gleam.toml resolve relative to the example's location at
# /build/aws-gleam-examples/fargate-smoke-test, so the SDK tree
# needs to be at /build/aws-gleam/...
COPY aws-gleam/        /build/aws-gleam/
COPY aws-gleam-examples/ /build/aws-gleam-examples/

WORKDIR /build/aws-gleam-examples/fargate-smoke-test

# regen.sh is a bash pipeline; alpine ships ash as /bin/sh.
RUN apk add --no-cache bash coreutils findutils grep sed

# `docker buildx` doesn't allocate a TTY; on OTP 27+ the kernel
# tries to attach the `user` IO process and crashes with
# `failed_to_start_child,user,nouser`. `-noinput` skips the
# attach. Implies -noshell.
ENV ERL_AFLAGS="-noinput"

RUN gleam deps download \
    && bash -c '(cd /build/aws-gleam && ./scripts/regen.sh s3 sqs)' \
    && gleam export erlang-shipment \
    && mv build/erlang-shipment /app \
    && rm -rf /build

WORKDIR /app

ENV ERL_FLAGS="+t 4194304"

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
