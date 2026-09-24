#!/usr/bin/env escript
%% Test: Named pool registration
%% Start a pool with a process name. Access it both via returned subject
%% and via named_subject lookup.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        PoolName = gleam@erlang@process:new_name(<<"escript_test_pool">>),
        Builder = puddle:name(
            puddle:size(puddle:new(fun() -> {ok, 99} end), 1),
            PoolName
        ),
        {ok, Manager} = puddle:start(Builder, 5000),

        %% Access via returned subject
        {ok, 99} = puddle:apply(Manager, fun(N) -> puddle:keep(N) end, 1000, fun(R) -> R end),

        %% Access via named subject
        Named = gleam@erlang@process:named_subject(PoolName),
        {ok, 99} = puddle:apply(Named, fun(N) -> puddle:keep(N) end, 1000, fun(R) -> R end),

        puddle:shutdown(Manager),
        timer:sleep(50),
        io:format("PASS: named pool accessible via name and subject~n"),
        halt(0)
    catch
        Class:Reason:ST ->
            io:format("ERROR: ~p:~p~n~p~n", [Class, Reason, ST]),
            halt(2)
    end.
