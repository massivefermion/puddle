#!/usr/bin/env escript
%% Test: LIFO checkout strategy
%% Start a pool with 3 resources and LIFO strategy. Check out all 3,
%% note order. Check all back in. Re-checkout and verify LIFO order
%% (last returned = first checked out).
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        Builder = puddle:checkout_strategy(
            puddle:size(puddle:new(fun() -> {ok, 0} end), 3),
            l_i_f_o
        ),
        {ok, M} = puddle:start(Builder, 5000),

        %% Check out all 3 resources and record their PIDs (used as identity)
        {ok, V1} = puddle:apply(M, fun(N) -> puddle:keep(N) end, 1000, fun(R) -> R end),
        {ok, V2} = puddle:apply(M, fun(N) -> puddle:keep(N) end, 1000, fun(R) -> R end),
        {ok, V3} = puddle:apply(M, fun(N) -> puddle:keep(N) end, 1000, fun(R) -> R end),

        %% Resources returned in order V1, V2, V3
        %% With LIFO, next checkout should get V3 (last in, first out)
        {ok, R1} = puddle:apply(M, fun(N) -> puddle:keep(N) end, 1000, fun(R) -> R end),

        puddle:shutdown(M),
        timer:sleep(50),

        %% V3 was last returned, so with LIFO it should be checked out first
        io:format("V3=~p R1=~p~n", [V3, R1]),
        case R1 of
            V3 ->
                io:format("PASS: LIFO checkout returned last-returned resource~n"),
                halt(0);
            _ ->
                io:format("FAIL: LIFO did not return last-returned resource~n"),
                halt(1)
        end
    catch
        Class:Reason:ST ->
            io:format("ERROR: ~p:~p~n~p~n", [Class, Reason, ST]),
            halt(2)
    end.
