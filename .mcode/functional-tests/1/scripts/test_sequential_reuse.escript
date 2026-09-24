#!/usr/bin/env escript
%% Test: sequential reuse from the same process
%% Start a pool with 1 resource, apply 3 times sequentially from the same process.
%% This validates that explicit check-in works correctly (the primary bug fix).
%% On origin (broken check-in): 2nd apply fails because resource stays "busy".
%% On target (fixed check-in): all 3 applies succeed.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        {ok, M} = puddle:start(1, fun() -> {ok, 42} end, 5000),
        R1 = puddle:apply(M, fun(N) -> N * 2 end, 2000, fun(R) -> R end),
        R2 = (catch puddle:apply(M, fun(N) -> N + 1 end, 2000, fun(R) -> R end)),
        R3 = (catch puddle:apply(M, fun(N) -> N end, 2000, fun(R) -> R end)),
        puddle:shutdown(M, fun(_) -> nil end),
        timer:sleep(50),
        io:format("R1=~p R2=~p R3=~p~n", [R1, R2, R3]),
        case {R1, R2, R3} of
            {{ok, 84}, {ok, 43}, {ok, 42}} ->
                io:format("PASS: sequential reuse works correctly~n"),
                halt(0);
            _ ->
                io:format("FAIL: sequential reuse did not produce expected results~n"),
                halt(1)
        end
    catch
        Class:Reason:ST ->
            io:format("ERROR: ~p:~p~n~p~n", [Class, Reason, ST]),
            halt(2)
    end.
