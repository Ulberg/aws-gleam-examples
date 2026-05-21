//// Lambda Runtime API client + typed event dispatchers. Mirrors the
//// shape of [glambda](https://github.com/ryanmiville/glambda) but
//// targets the Erlang BEAM (via a container image on Lambda's
//// `provided.al2023` custom runtime) rather than the Node.js
//// runtime.
////
//// Pattern is the same as glambda:
////   1. User writes a `Handler(event, result) = fn(event, Context)
////      -> Result(result, String)`, taking a typed event record.
////   2. An adapter like `lambda.sqs_handler(user_fn)` decodes the
////      raw Lambda payload into the typed event and routes the
////      `Result` back into the Runtime API's response/error endpoints.
////   3. `lambda.run(handler)` polls forever.
////
//// Difference from glambda: no `Promise(result)` — the BEAM doesn't
//// need explicit async because each invocation is its own process.
//// Difference from our earlier `runtime_api.gleam`: handlers see
//// strongly-typed events (`SqsEvent`, `Context`) instead of raw
//// `BitArray`.

import aws/services/sqs
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// ---------- Context ----------

/// Per-invocation metadata Lambda hands to every handler. Mirrors the
/// glambda `Context` record (also Rust SDK's `LambdaContext`). We
/// drop the JS-specific `client_context` / `identity` (used by mobile
/// SDK invocations) — re-add if a real use case ever needs them.
pub type Context {
  Context(
    function_name: String,
    function_version: String,
    invoked_function_arn: String,
    memory_limit_in_mb: String,
    aws_request_id: String,
    log_group_name: String,
    log_stream_name: String,
    deadline_ms: String,
    trace_id: String,
  )
}

// ---------- SQS event ----------

pub type SqsEvent {
  SqsEvent(records: List(SqsRecord))
}

/// One SQS message delivered by the Lambda event source mapping.
/// `message` is the SDK's own `sqs.Message` type — same shape the
/// `sqs.receive_message` op returns when polling SQS directly — so
/// handlers can pass `record.message` straight to any helper that
/// accepts a `sqs.Message`. The three Lambda-specific fields
/// (event_source / event_source_arn / aws_region) live alongside.
///
/// `sqs.Message` fields are all `Option(_)` (Smithy faithfulness —
/// the SQS API technically allows servers to omit any of them). On
/// the Lambda event side `message_id` / `receipt_handle` / `body` /
/// `md5_of_body` are always populated, so the decoder below wraps
/// them in `Some(_)`; the rest stay `None`.
pub type SqsRecord {
  SqsRecord(
    message: sqs.Message,
    event_source: String,
    event_source_arn: String,
    aws_region: String,
  )
}

/// Partial-batch failure: SQS event source mapping treats any
/// message ID in `batch_item_failures` as failed (Lambda redrives
/// it) while the rest are considered processed. If the handler
/// returns `None` the whole batch is treated as successful.
pub type SqsBatchResponse {
  SqsBatchResponse(batch_item_failures: List(String))
}

// ---------- handler shape ----------

pub type Handler(event, result) =
  fn(event, Context) -> Result(result, String)

// ---------- the polling loop ----------

pub type RuntimeError {
  Transport(reason: String)
  MissingEnv
  MalformedNext(missing_header: String)
}

const api_version: String = "2018-06-01"

/// Wrap a user handler in the SQS event dispatcher: decode the raw
/// payload into `SqsEvent`, call the handler, marshal the typed
/// `Option(SqsBatchResponse)` back into JSON the Lambda runtime
/// understands.
///
/// `None` signals "all messages processed" (empty batch_item_failures
/// list, same wire shape AWS expects).
pub fn sqs_handler(
  user: Handler(SqsEvent, Option(SqsBatchResponse)),
) -> fn(Invocation) -> Result(BitArray, String) {
  fn(inv: Invocation) {
    let Invocation(request_id: _, payload: payload, context: ctx, ..) = inv
    use envelope_str <- result.try(
      bit_array.to_string(payload)
      |> result.replace_error("Lambda payload was not UTF-8"),
    )
    use event <- result.try(decode_sqs_event(envelope_str))
    use response <- result.try(user(event, ctx))
    Ok(bit_array.from_string(encode_sqs_batch_response(response)))
  }
}

fn decode_sqs_event(payload: String) -> Result(SqsEvent, String) {
  let record_decoder = {
    use message_id <- decode.field("messageId", decode.string)
    use receipt_handle <- decode.field("receiptHandle", decode.string)
    use body <- decode.field("body", decode.string)
    use md5_of_body <- decode.field("md5OfBody", decode.string)
    use event_source <- decode.field("eventSource", decode.string)
    use event_source_arn <- decode.field("eventSourceARN", decode.string)
    use aws_region <- decode.field("awsRegion", decode.string)
    // Build the SDK's `sqs.Message` from the JSON envelope. The
    // Lambda event always carries message_id / receipt_handle /
    // body / md5_of_body so they're wrapped in Some; attributes
    // and message_attributes aren't decoded here (we don't need
    // them for the smoke-test; add to the decoder above if you
    // do).
    let message =
      sqs.Message(
        ..sqs.message_default(),
        body: Some(body),
        md5_of_body: Some(md5_of_body),
        message_id: Some(message_id),
        receipt_handle: Some(receipt_handle),
      )
    decode.success(SqsRecord(
      message: message,
      event_source: event_source,
      event_source_arn: event_source_arn,
      aws_region: aws_region,
    ))
  }
  let envelope_decoder = {
    use records <- decode.field("Records", decode.list(record_decoder))
    decode.success(SqsEvent(records: records))
  }
  json.parse(payload, envelope_decoder)
  |> result.map_error(fn(e) { "SQS event decode failed: " <> string.inspect(e) })
}

fn encode_sqs_batch_response(response: Option(SqsBatchResponse)) -> String {
  case response {
    None -> "{\"batchItemFailures\":[]}"
    Some(SqsBatchResponse(batch_item_failures: ids)) -> {
      json.object([
        #(
          "batchItemFailures",
          json.array(ids, of: fn(id) {
            json.object([#("itemIdentifier", json.string(id))])
          }),
        ),
      ])
      |> json.to_string
    }
  }
}

/// Run the dispatcher loop forever. Each iteration:
///   1. GET /next — block until Lambda has an invocation
///   2. call the wrapped handler
///   3. POST /response on success / POST /error on failure
///   4. loop
pub fn run(handler: fn(Invocation) -> Result(BitArray, String)) -> Nil {
  case run_once(handler) {
    Ok(_) -> run(handler)
    Error(_) -> Nil
  }
}

// ---------- runtime API plumbing ----------

pub type Invocation {
  Invocation(
    request_id: String,
    function_arn: String,
    deadline_ms: String,
    trace_id: String,
    payload: BitArray,
    context: Context,
  )
}

fn run_once(
  handler: fn(Invocation) -> Result(BitArray, String),
) -> Result(Nil, RuntimeError) {
  use inv <- result.try(next())
  case handler(inv) {
    Ok(body) -> {
      let _ = respond(inv.request_id, body)
      Ok(Nil)
    }
    Error(reason) -> {
      let _ = report_error(inv.request_id, "HandlerError", reason)
      Ok(Nil)
    }
  }
}

fn next() -> Result(Invocation, RuntimeError) {
  use api_host <- result.try(runtime_api_host())
  let url =
    "http://"
    <> api_host
    <> "/"
    <> api_version
    <> "/runtime/invocation/next"
  use req <- result.try(
    request.to(url)
    |> result.replace_error(Transport(reason: "bad url: " <> url)),
  )
  use resp <- result.try(send(
    req |> request.set_method(http.Get) |> request.set_body(<<>>),
  ))
  use req_id <- result.try(required_header(resp, "lambda-runtime-aws-request-id"))
  use arn <- result.try(required_header(
    resp,
    "lambda-runtime-invoked-function-arn",
  ))
  use deadline <- result.try(required_header(
    resp,
    "lambda-runtime-deadline-ms",
  ))
  let trace = result.unwrap(header_value(resp, "lambda-runtime-trace-id"), "")
  Ok(Invocation(
    request_id: req_id,
    function_arn: arn,
    deadline_ms: deadline,
    trace_id: trace,
    payload: resp.body,
    context: context_from(req_id, arn, deadline, trace),
  ))
}

fn context_from(
  request_id: String,
  arn: String,
  deadline: String,
  trace: String,
) -> Context {
  Context(
    function_name: env_or("AWS_LAMBDA_FUNCTION_NAME", "unknown"),
    function_version: env_or("AWS_LAMBDA_FUNCTION_VERSION", "$LATEST"),
    invoked_function_arn: arn,
    memory_limit_in_mb: env_or("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "0"),
    aws_request_id: request_id,
    log_group_name: env_or("AWS_LAMBDA_LOG_GROUP_NAME", ""),
    log_stream_name: env_or("AWS_LAMBDA_LOG_STREAM_NAME", ""),
    deadline_ms: deadline,
    trace_id: trace,
  )
}

fn env_or(name: String, default: String) -> String {
  result.unwrap(os_getenv(name), default)
}

fn respond(request_id: String, body: BitArray) -> Result(Nil, RuntimeError) {
  use api_host <- result.try(runtime_api_host())
  let url =
    "http://"
    <> api_host
    <> "/"
    <> api_version
    <> "/runtime/invocation/"
    <> request_id
    <> "/response"
  use req <- result.try(
    request.to(url) |> result.replace_error(Transport("bad url: " <> url)),
  )
  use _ <- result.try(send(
    req |> request.set_method(http.Post) |> request.set_body(body),
  ))
  Ok(Nil)
}

fn report_error(
  request_id: String,
  error_type: String,
  message: String,
) -> Result(Nil, RuntimeError) {
  use api_host <- result.try(runtime_api_host())
  let url =
    "http://"
    <> api_host
    <> "/"
    <> api_version
    <> "/runtime/invocation/"
    <> request_id
    <> "/error"
  let payload =
    "{\"errorType\":\""
    <> escape_json(error_type)
    <> "\",\"errorMessage\":\""
    <> escape_json(message)
    <> "\"}"
  use req <- result.try(
    request.to(url) |> result.replace_error(Transport("bad url: " <> url)),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("lambda-runtime-function-error-type", error_type)
    |> request.set_body(bit_array.from_string(payload))
  use _ <- result.try(send(req))
  Ok(Nil)
}

// `os:getenv/1` BIF takes a charlist (Erlang string), but Gleam
// `String` is a binary. Bypass through `lambda_ffi:getenv/1` which
// converts both sides.
@external(erlang, "lambda_ffi", "getenv")
fn os_getenv(name: String) -> Result(String, Nil)

fn runtime_api_host() -> Result(String, RuntimeError) {
  case os_getenv("AWS_LAMBDA_RUNTIME_API") {
    Ok(host) if host != "" -> Ok(host)
    _ -> Error(MissingEnv)
  }
}

fn send(
  req: request.Request(BitArray),
) -> Result(response.Response(BitArray), RuntimeError) {
  httpc.send_bits(req)
  |> result.map_error(fn(e) { Transport(reason: string.inspect(e)) })
}

fn required_header(
  resp: response.Response(BitArray),
  name: String,
) -> Result(String, RuntimeError) {
  case header_value(resp, name) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(MalformedNext(missing_header: name))
  }
}

fn header_value(
  resp: response.Response(BitArray),
  name: String,
) -> Result(String, Nil) {
  list.find_map(resp.headers, fn(h) {
    case string.lowercase(h.0) == name {
      True -> Ok(h.1)
      False -> Error(Nil)
    }
  })
}

fn escape_json(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}
