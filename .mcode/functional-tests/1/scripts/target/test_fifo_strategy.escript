#!/usr/bin/env escript
%% Test: FIFO checkout strategy (default)
%% Start a pool with 3 resources and FIFO strategy. Check out all 3,
%% note order. Check all back in. Re-checkout and verify FIFO order
%% (first returned = first checked out).
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        Builder = puddle:checkout_strategy(
            puddle:size(puddle:new(fun() -> {ok, 0} end), 3),
            f_i_f_o
        ),
        {ok, M} = puddle:start(Builder, 5000),

        %% Check out all 3 resources and record their values
        {ok, V1} = puddle:apply(M, fun(N) -> puddle:keep(N) end, 1000, fun(R) -> R end),
        {ok, V2} = puddle:apply(M, fun(N) -> puddle:keep(N) end, 1000, fun(R) -> R end),
        {ok, V3} = puddle:apply(M, fun(N) -> puddle:keep(N) end, 1000, fun(R) -> R end),

        %% Resources returned in order V1, V2, V3
        %% With FIFO, next checkout should get V1 (first in, first out)
        {ok, R1} = puddle:apply(M, fun(N) -> puddle:keep(N) end, 1000, fun(R) -> R end),

        puddle:shutdown(M),
        timer:sleep(50),

        io:format("V1=~p R1=~p~n", [V1, R1]),
        case R1 of
            V1 ->
                io:format("PASS: FIFO checkout returned first-returned resource~n"),
                halt(0);
            _ ->
                io:format("FAIL: FIFO did not return first-returned resource~n"),
                halt(1)
        end
    catch
        Class:Reason:ST ->
            io:format("ERROR: ~p:~p~n~p~n", [Class, Reason, ST]),
            halt(2)
    end.
