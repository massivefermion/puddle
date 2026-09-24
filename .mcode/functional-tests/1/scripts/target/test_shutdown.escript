#!/usr/bin/env escript
%% Test: pool shutdown with on_shutdown callback configured via builder
%% Start a pool with 2 resources and on_shutdown callback. Call shutdown().
%% Verify the callback is called for both resources.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        Self = self(),
        Builder = puddle:on_shutdown(
            puddle:size(puddle:new(fun() -> {ok, 42} end), 2),
            fun(_Resource) -> Self ! shutdown_called end
        ),
        {ok, M} = puddle:start(Builder, 5000),

        puddle:shutdown(M),

        Count = count_shutdown_messages(0, 3000),

        case Count of
            2 ->
                io:format("PASS: on_shutdown callback called for all 2 resources~n"),
                halt(0);
            Other ->
                io:format("FAIL: expected 2 shutdown calls, got ~p~n", [Other]),
                halt(1)
        end
    catch
        Class:Reason:ST ->
            io:format("ERROR: ~p:~p~n~p~n", [Class, Reason, ST]),
            halt(2)
    end.

count_shutdown_messages(Count, Timeout) ->
    receive
        shutdown_called -> count_shutdown_messages(Count + 1, Timeout)
    after Timeout ->
        Count
    end.
