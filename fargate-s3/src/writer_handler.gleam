//// Writer-role one-shot task. Reads a payload, writes it to S3
//// under a per-run key, sends the key on to SQS, then exits.
////
//// `SMOKE_PAYLOAD` is the canonical input — Fargate's RunTask
//// passes it via the task's `environment` overrides. When unset
//// the writer falls back to a default string so a bare
//// `run-task` invocation still produces a verifiable round-trip.

import aws/env
import aws/services/s3
import aws/services/sqs
import aws/streaming
import gleam/bit_array
import gleam/int
import gleam/option.{Some}
import gleam/result
import gleam/string

const default_payload: String = "hello from aws-gleam fargate-s3"

pub fn run() -> Result(String, String) {
  use bucket <- env_required("SMOKE_BUCKET")
  use queue_url <- env_required("SMOKE_QUEUE_URL")

  use s3_client <- try_step("s3_client_init", s3.new())
  use sqs_client <- try_step("sqs_client_init", sqs.new())

  let payload = case env.get_env("SMOKE_PAYLOAD") {
    Ok(p) if p != "" -> p
    _ -> default_payload
  }
  let key = "events/" <> mint_key_suffix() <> ".bin"
  let body = bit_array.from_string(payload)

  let put_outcome = put_payload(s3_client, bucket, key, body)
  s3.shutdown(s3_client)
  use _ <- result.try(put_outcome)

  let send_outcome = send_key(sqs_client, queue_url, key)
  sqs.shutdown(sqs_client)
  use _ <- result.try(send_outcome)

  Ok(
    "writer ok: wrote s3://"
    <> bucket
    <> "/"
    <> key
    <> " ("
    <> int.to_string(bit_array.byte_size(body))
    <> " bytes), enqueued to "
    <> queue_url,
  )
}

fn mint_key_suffix() -> String {
  // `erlang:unique_integer/0` is guaranteed unique within this BEAM
  // node's lifetime. Negative values are possible in some OTP
  // versions; abs them out so the key looks tidy.
  int.to_string(int_abs(unique_integer()))
}

fn int_abs(n: Int) -> Int {
  case n < 0 {
    True -> -n
    False -> n
  }
}

fn put_payload(
  client: s3.Client,
  bucket: String,
  key: String,
  body: BitArray,
) -> Result(Nil, String) {
  let input =
    s3.PutObjectRequest(
      ..s3.put_object_request_default(),
      body: Some(streaming.from_bit_array(body)),
      bucket: Some(bucket),
      content_length: Some(bit_array.byte_size(body)),
      content_type: Some("application/octet-stream"),
      key: Some(key),
    )
  case s3.put_object(client, input) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error("s3.put_object: " <> string.inspect(e))
  }
}

fn send_key(
  client: sqs.Client,
  queue_url: String,
  key: String,
) -> Result(Nil, String) {
  let input =
    sqs.SendMessageRequest(
      ..sqs.send_message_request_default(),
      message_body: Some(key),
      queue_url: Some(queue_url),
    )
  case sqs.send_message(client, input) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error("sqs.send_message: " <> string.inspect(e))
  }
}

fn env_required(
  name: String,
  k: fn(String) -> Result(a, String),
) -> Result(a, String) {
  case env.get_env(name) {
    Ok(v) if v != "" -> k(v)
    _ -> Error("missing required env var: " <> name)
  }
}

fn try_step(
  step: String,
  res: Result(a, e),
  k: fn(a) -> Result(b, String),
) -> Result(b, String) {
  case res {
    Ok(v) -> k(v)
    Error(e) -> Error(step <> ": " <> string.inspect(e))
  }
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
