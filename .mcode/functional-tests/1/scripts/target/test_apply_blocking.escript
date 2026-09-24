#!/usr/bin/env escript
%% Test: Blocking checkout (apply_blocking)
%% Start a pool with 1 resource. Hold it for 300ms.
%% Non-blocking apply should fail immediately.
%% Blocking apply_blocking should wait and succeed.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        Builder = puddle:size(puddle:new(fun() -> {ok, 1} end), 1),
        {ok, M} = puddle:start(Builder, 5000),
        Self = self(),

        %% Hold the single resource for 400ms
        spawn(fun() ->
            R = (catch puddle:apply(M, fun(N) ->
                timer:sleep(400),
                puddle:keep(N)
            end, 5000, fun(X) -> X end)),
            Self ! {holder_done, R}
        end),

        timer:sleep(50),

        %% Non-blocking apply should fail immediately
        NonBlockResult = (catch puddle:apply(M, fun(N) -> puddle:keep(N) end, 100, fun(X) -> X end)),

        %% Blocking apply_blocking should wait and succeed
        spawn(fun() ->
            R = (catch puddle:apply_blocking(M, fun(N) -> puddle:keep(N) end, 5000, fun(X) -> X end)),
            Self ! {blocking_done, R}
        end),

        %% Wait for holder to finish
        receive {holder_done, _} -> ok after 5000 -> error(holder_timeout) end,

        %% Wait for blocking request to complete
        BlockResult = receive {blocking_done, R} -> R after 5000 -> error(blocking_timeout) end,

        puddle:shutdown(M),
        timer:sleep(50),

        io:format("nonblock=~p block=~p~n", [NonBlockResult, BlockResult]),
        case {NonBlockResult, BlockResult} of
            {{error, _}, {ok, 1}} ->
                io:format("PASS: non-blocking fails, blocking waits and succeeds~n"),
                halt(0);
            _ ->
                io:format("FAIL: unexpected results~n"),
                halt(1)
        end
    catch
        Class:Reason:ST ->
            io:format("ERROR: ~p:~p~n~p~n", [Class, Reason, ST]),
            halt(2)
    end.
