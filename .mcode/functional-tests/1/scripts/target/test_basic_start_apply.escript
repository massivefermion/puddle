#!/usr/bin/env escript
%% Test: basic pool start (builder pattern) and apply with Keep type
%% Start a pool using the builder: new -> size -> start, apply a function
%% that returns keep(N * 2), verify the result.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        Builder = puddle:size(puddle:new(fun() -> {ok, 42} end), 2),
        {ok, Manager} = puddle:start(Builder, 5000),
        Result = puddle:apply(Manager, fun(N) -> puddle:keep(N * 2) end, 5000, fun(R) -> R end),
        puddle:shutdown(Manager),
        timer:sleep(50),
        case Result of
            {ok, 84} ->
                io:format("PASS: builder start and apply returned {ok, 84}~n"),
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
