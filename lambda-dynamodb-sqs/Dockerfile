# Lambda container image for the lambda-dynamodb-sqs example.
#
# Build context = the parent directory of this repo (set by
# build.sh: `docker buildx ... ../..`), so it contains both this
# repo (aws-gleam-examples) AND the SDK repo (aws-gleam) as
# sibling checkouts. The example's path deps to
# `../../aws-gleam/{runtime,services/dynamodb,services/sqs}`
# resolve once both are copied in.
#
# Post-hex-publish this simplifies dramatically: no more sibling
# repo copy, no in-image regen — just `gleam deps download` from
# hex.

FROM ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine

COPY aws-gleam/        /build/aws-gleam/
COPY aws-gleam-examples/ /build/aws-gleam-examples/

WORKDIR /build/aws-gleam-examples/lambda-dynamodb-sqs

# regen.sh is bash; alpine ships ash as /bin/sh.
RUN apk add --no-cache bash coreutils findutils grep sed

# `docker buildx` has no TTY; OTP 27+ kernel crashes attaching
# `user` IO without -noinput. Compile-time only — safe.
ENV ERL_AFLAGS="-noinput"

RUN gleam deps download \
    && bash -c '(cd /build/aws-gleam && ./scripts/regen.sh dynamodb sqs)' \
    && gleam export erlang-shipment \
    && mv build/erlang-shipment /app \
    && rm -rf /build

WORKDIR /app
ENV ERL_FLAGS="+t 4194304"

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
