#!/usr/bin/env escript
%% Test: Lazy resource creation
%% Start a pool with size 3 and Lazy creation strategy.
%% Verify no resources created at init. First apply creates one on demand.
%% Second apply reuses the idle resource (no new creation).
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        Self = self(),
        Builder = puddle:creation_strategy(
            puddle:size(puddle:new(fun() ->
                Self ! resource_created,
                {ok, 42}
            end), 3),
            lazy
        ),
        {ok, M} = puddle:start(Builder, 5000),

        %% No resources should be created yet (lazy)
        receive resource_created -> io:format("FAIL: resource created at init~n"), halt(1)
        after 100 -> ok
        end,

        %% First apply should create one resource on demand
        {ok, 42} = puddle:apply(M, fun(N) -> puddle:keep(N) end, 2000, fun(R) -> R end),

        %% Should have received one creation message
        receive resource_created -> ok
        after 100 -> io:format("FAIL: no resource created on first apply~n"), halt(1)
        end,

        %% Second apply reuses idle resource (no new creation)
        {ok, 42} = puddle:apply(M, fun(N) -> puddle:keep(N) end, 2000, fun(R) -> R end),

        receive resource_created -> io:format("FAIL: unexpected second creation~n"), halt(1)
        after 100 -> ok
        end,

        puddle:shutdown(M),
        timer:sleep(50),
        io:format("PASS: lazy creation creates resources on demand~n"),
        halt(0)
    catch
        Class:Reason:ST ->
            io:format("ERROR: ~p:~p~n~p~n", [Class, Reason, ST]),
            halt(2)
    end.
