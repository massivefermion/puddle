#!/usr/bin/env escript
%% Test: Resource discard (Keep vs Discard)
%% Start a pool with 1 resource. Apply with discard() to signal the resource
%% should be destroyed. Verify a replacement is spawned and pool stays functional.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        Self = self(),
        Builder = puddle:size(puddle:new(fun() ->
            Self ! resource_created,
            {ok, 42}
        end), 1),
        {ok, M} = puddle:start(Builder, 5000),

        %% Drain the initial creation message
        receive resource_created -> ok after 200 -> ok end,

        %% Discard the resource
        {ok, 42} = puddle:apply(M, fun(N) -> puddle:discard(N) end, 2000, fun(R) -> R end),

        %% Wait for replacement to be created
        timer:sleep(200),

        %% A new creation message should have arrived (replacement)
        receive resource_created -> ok
        after 200 -> io:format("FAIL: no replacement created after discard~n"), halt(1)
        end,

        %% Pool should still be functional
        {ok, 42} = puddle:apply(M, fun(N) -> puddle:keep(N) end, 2000, fun(R) -> R end),

        puddle:shutdown(M),
        timer:sleep(50),
        io:format("PASS: discard destroys resource and spawns replacement~n"),
        halt(0)
    catch
        Class:Reason:ST ->
            io:format("ERROR: ~p:~p~n~p~n", [Class, Reason, ST]),
            halt(2)
    end.
