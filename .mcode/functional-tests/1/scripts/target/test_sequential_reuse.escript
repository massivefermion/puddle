#!/usr/bin/env escript
%% Test: sequential reuse from the same process with Next type
%% Start a pool with 1 resource using builder. Apply 3 times sequentially.
%% Validates explicit check-in works correctly with the new API.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        Builder = puddle:size(puddle:new(fun() -> {ok, 42} end), 1),
        {ok, M} = puddle:start(Builder, 5000),
        R1 = puddle:apply(M, fun(N) -> puddle:keep(N * 2) end, 2000, fun(R) -> R end),
        R2 = (catch puddle:apply(M, fun(N) -> puddle:keep(N + 1) end, 2000, fun(R) -> R end)),
        R3 = (catch puddle:apply(M, fun(N) -> puddle:keep(N) end, 2000, fun(R) -> R end)),
        puddle:shutdown(M),
        timer:sleep(50),
        io:format("R1=~p R2=~p R3=~p~n", [R1, R2, R3]),
        case {R1, R2, R3} of
            {{ok, 84}, {ok, 43}, {ok, 42}} ->
                io:format("PASS: sequential reuse works correctly with builder API~n"),
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
