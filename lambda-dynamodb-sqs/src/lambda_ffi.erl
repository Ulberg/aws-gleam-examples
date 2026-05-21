%% FFI shim for OS env access. Gleam `String` compiles to Erlang
%% binary; `os:getenv/1` is a BIF that wants a charlist (list of
%% ints), not a binary. Pass a binary in and you get
%% `erlang:error(Badarg)` at the Lambda runtime API loop's first
%% call. Convert binary <-> charlist on each side here.

-module(lambda_ffi).
-export([getenv/1]).

getenv(Name) when is_binary(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, list_to_binary(Value)}
    end.
