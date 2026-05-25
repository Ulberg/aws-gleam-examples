//// Directly-invoked AWS Lambda that stores each invocation payload
//// as an object in S3.
////
//// Invoke it with any payload (`aws lambda invoke --payload ...`);
//// the raw bytes are written to
//// `s3://$BUCKET_NAME/events/<request_id>.json` and the handler
//// replies with `{"stored":"<key>"}`. There's no SQS trigger and no
//// event source mapping — the Lambda is its own front door.
////
//// This is the minimal shape of running the aws-gleam SDK on Lambda
//// now that the Runtime API loop lives in the `aws_gleam_lambda`
//// package (`import aws/lambda`): `lambda.start` takes a
//// `fn(BitArray, Context) -> Result(BitArray, InvocationError)` and
//// polls forever. Contrast with the sibling lambda-dynamodb-sqs
//// example, which hand-rolled that loop locally (src/lambda.gleam)
//// before the package existed.
////
//// Environment variables (set by Terraform — see infra/main.tf):
////   BUCKET_NAME — S3 bucket to write into
////   AWS_REGION  — Lambda sets this automatically

import aws/lambda
import aws/services/s3
import aws/streaming
import gleam/bit_array
import gleam/option.{Some}
import gleam/string

pub fn main() {
  // Reads AWS_REGION + resolves creds via the default chain (env-first,
  // which is what Lambda populates). Built once, reused across invocations.
  let assert Ok(client) = s3.new_with_auto_region()
  // BUCKET_NAME is injected by Terraform. Crash at cold start if it's
  // missing — a Lambda with no target bucket is a deploy error, not
  // something to surface per-invocation.
  let assert Ok(bucket) = get_env("BUCKET_NAME")
  lambda.start(fn(payload, ctx) { store(client, bucket, payload, ctx) })
}

fn store(
  client: s3.Client,
  bucket: String,
  payload: BitArray,
  ctx: lambda.Context,
) -> Result(BitArray, lambda.InvocationError) {
  let key = "events/" <> ctx.request_id <> ".json"
  // `..put_object_request_default()` fills the ~50 optional fields with
  // None so you only set what you need. `body` is a streaming blob.
  let request =
    s3.PutObjectRequest(
      ..s3.put_object_request_default(),
      bucket: Some(bucket),
      key: Some(key),
      body: Some(streaming.from_bit_array(payload)),
    )
  case s3.put_object(client, request) {
    Ok(_) -> Ok(bit_array.from_string("{\"stored\":\"" <> key <> "\"}"))
    Error(e) -> Error(lambda.invocation_error("S3PutFailed", string.inspect(e)))
  }
}

// `os:getenv/1` BIF takes a charlist (Erlang string); Gleam `String`
// is a binary. Bypass through `lambda_s3_ffi:get_env/1` which converts
// both sides and maps the `false` miss onto `Error(Nil)`.
@external(erlang, "lambda_s3_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)
