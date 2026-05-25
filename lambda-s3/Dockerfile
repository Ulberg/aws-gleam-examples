# Lambda container image for the lambda-s3 example.
#
# Consumes aws_gleam_runtime + aws_gleam_lambda + aws_gleam_s3 from
# hex.pm — no sibling SDK checkout needed, no in-image regen.
# `gleam deps download` pulls everything from hex; `gleam export
# erlang-shipment` produces the OTP release the entrypoint runs.

FROM ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine

WORKDIR /build
COPY . /build/

# `docker buildx` has no TTY; OTP 27+ kernel crashes attaching
# `user` IO without -noinput. Compile-time only, safe.
ENV ERL_AFLAGS="-noinput"

RUN gleam deps download \
    && gleam export erlang-shipment \
    && mv build/erlang-shipment /app \
    && rm -rf /build

WORKDIR /app
ENV ERL_FLAGS="+t 4194304"

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
