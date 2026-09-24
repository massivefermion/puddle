#!/usr/bin/env escript
%% Test: pool shutdown
%% Start a pool with 2 resources. Call shutdown with a callback that sends
%% a message for each resource. Verify the callback is called for both resources.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        Self = self(),
        {ok, M} = puddle:start(2, fun() -> {ok, 42} end, 5000),

        %% Shutdown the pool; callback sends a message for each resource
        puddle:shutdown(M, fun(_Resource) -> Self ! shutdown_called end),

        %% Count shutdown notifications
        Count = count_shutdown_messages(0, 3000),

        case Count of
            2 ->
                io:format("PASS: shutdown called for all 2 resources~n"),
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
