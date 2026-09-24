#!/usr/bin/env escript
%% Test: basic pool start and apply
%% Start a pool with 2 resources, apply a function that doubles the value,
%% verify the result is correct.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        {ok, Manager} = puddle:start(2, fun() -> {ok, 42} end, 5000),
        Result = puddle:apply(Manager, fun(N) -> N * 2 end, 5000, fun(R) -> R end),
        puddle:shutdown(Manager, fun(_) -> nil end),
        timer:sleep(50),
        case Result of
            {ok, 84} ->
                io:format("PASS: basic start and apply returned {ok, 84}~n"),
                halt(0);
            Other ->
                io:format("FAIL: expected {ok, 84}, got ~p~n", [Other]),
                halt(1)
        end
    catch
        Class:Reason:ST ->
            io:format("ERROR: ~p:~p~n~p~n", [Class, Reason, ST]),
            halt(2)
    end.
