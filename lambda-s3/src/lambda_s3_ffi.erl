%% FFI shim for OS env access. Gleam `String` compiles to an Erlang
%% binary; `os:getenv/1` is a BIF that wants a charlist (list of
%% ints), not a binary — pass a binary in and you get a `badarg`.
%% Convert binary <-> charlist on each side here, and map the `false`
%% miss onto `{error, nil}` so the Gleam side sees a
%% `Result(String, Nil)`.

-module(lambda_s3_ffi).
-export([get_env/1]).

get_env(Name) when is_binary(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
