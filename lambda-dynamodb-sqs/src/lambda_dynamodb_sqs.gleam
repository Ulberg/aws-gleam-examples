//// SQS-triggered Lambda handler that lands each incoming message
//// into a DynamoDB table.
////
//// Expected SQS message body shape (JSON):
////   { "user_id": "U-123", "data": "anything" }
////
//// For each record, the handler:
////   1. Parses the JSON body
////   2. PutItem-s a DynamoDB row keyed on user_id, with
////      data + received_at columns
////
//// Per-message failures (parse errors, DynamoDB rejections)
//// surface as partial-batch failures via SqsBatchResponse — Lambda
//// then redrives only those specific messages, the rest are
//// considered processed and removed from the queue.
////
//// Environment variables (set by Terraform):
////   TABLE_NAME — DynamoDB table to write into
////   AWS_REGION — Lambda sets automatically

import aws/services/dynamodb
import gleam/dict
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lambda.{
  type Context, type SqsBatchResponse, type SqsEvent, type SqsRecord,
  SqsBatchResponse,
}

pub fn main() {
  // Lambda container starts -> enter the Runtime API loop with our
  // typed SQS handler wrapping `handle`. Auto-region picks
  // AWS_REGION which Lambda sets.
  lambda.run(lambda.sqs_handler(handle))
}

/// Handle one batch of SQS records. Per-message errors surface in
/// `batch_item_failures` so Lambda redrives the failing ones; the
/// rest are removed from the queue cleanly.
fn handle(
  event: SqsEvent,
  ctx: Context,
) -> Result(Option(SqsBatchResponse), String) {
  use table_name <- result.try(env_required("TABLE_NAME"))
  use client <- result.try(
    dynamodb.new_with_auto_region()
    |> result.map_error(fn(e) {
      "dynamodb_client_init: " <> string.inspect(e)
    }),
  )

  io.println(
    "request_id="
    <> ctx.aws_request_id
    <> " records="
    <> string.inspect(list.length(event.records)),
  )

  // Process every record. Each failure goes into batch_item_failures
  // by message_id; the rest are silently considered successful.
  let failures =
    list.filter_map(event.records, fn(r) {
      case process_record(client, table_name, r) {
        Ok(_) -> Error(Nil)
        Error(reason) -> {
          io.println_error(
            "msg=" <> r.message_id <> " failed: " <> reason,
          )
          Ok(r.message_id)
        }
      }
    })

  dynamodb.shutdown(client)

  case failures {
    [] -> Ok(None)
    ids -> Ok(Some(SqsBatchResponse(batch_item_failures: ids)))
  }
}

// ---------- per-record work ----------

type Message {
  Message(user_id: String, data: String)
}

fn process_record(
  client: dynamodb.Client,
  table_name: String,
  record: SqsRecord,
) -> Result(Nil, String) {
  use msg <- result.try(decode_message(record.body))
  put_item(client, table_name, msg, record.message_id)
}

fn decode_message(body: String) -> Result(Message, String) {
  let decoder = {
    use user_id <- decode.field("user_id", decode.string)
    use data <- decode.field("data", decode.string)
    decode.success(Message(user_id: user_id, data: data))
  }
  json.parse(body, decoder)
  |> result.map_error(fn(e) {
    "json decode failed: " <> string.inspect(e)
  })
}

fn put_item(
  client: dynamodb.Client,
  table_name: String,
  msg: Message,
  message_id: String,
) -> Result(Nil, String) {
  let item =
    dict.from_list([
      #("user_id", dynamodb.AttributeValueS(msg.user_id)),
      #("data", dynamodb.AttributeValueS(msg.data)),
      #("source_message_id", dynamodb.AttributeValueS(message_id)),
    ])
  let input =
    dynamodb.PutItemInput(
      condition_expression: None,
      conditional_operator: None,
      expected: None,
      expression_attribute_names: None,
      expression_attribute_values: None,
      item: Some(item),
      return_consumed_capacity: None,
      return_item_collection_metrics: None,
      return_values: None,
      return_values_on_condition_check_failure: None,
      table_name: Some(table_name),
    )
  case dynamodb.put_item(client, input) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error("put_item: " <> string.inspect(e))
  }
}

// ---------- helpers ----------

fn env_required(name: String) -> Result(String, String) {
  case os_getenv(name) {
    Ok(v) -> Ok(v)
    Error(_) -> Error("missing required env var: " <> name)
  }
}

@external(erlang, "os", "getenv")
fn os_getenv(name: String) -> Result(String, Nil)
