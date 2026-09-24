#!/usr/bin/env escript
%% Test: Pool status introspection
%% Verify status returns correct state (Ready/Full/Overloaded) and counts.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        Builder = puddle:size(puddle:new(fun() -> {ok, 1} end), 3),
        {ok, M} = puddle:start(Builder, 5000),

        %% Initially: Ready, 3 available, 0 busy, 0 waiting
        S1 = puddle:status(M, 1000),
        io:format("status1=~p~n", [S1]),
        {pool_status, ready, 3, 3, 0, 0} = S1,

        %% Hold all 3 resources
        Self = self(),
        lists:foreach(fun(I) ->
            spawn(fun() ->
                R = (catch puddle:apply(M, fun(N) ->
                    timer:sleep(600),
                    puddle:keep(N)
                end, 5000, fun(X) -> X end)),
                Self ! {task_done, I, R}
            end)
        end, [1, 2, 3]),

        timer:sleep(50),

        %% Now: Full, 0 available, 3 busy, 0 waiting
        S2 = puddle:status(M, 1000),
        io:format("status2=~p~n", [S2]),
        {pool_status, full, 3, 0, 3, 0} = S2,

        %% Add a blocking waiter
        spawn(fun() ->
            R = (catch puddle:apply_blocking(M, fun(N) -> puddle:keep(N) end, 5000, fun(X) -> X end)),
            Self ! {waiter_done, R}
        end),

        timer:sleep(50),

        %% Now: Overloaded, 0 available, 3 busy, 1 waiting
        S3 = puddle:status(M, 1000),
        io:format("status3=~p~n", [S3]),
        {pool_status, overloaded, 3, 0, 3, 1} = S3,

        %% Wait for all to complete
        receive {task_done, 1, _} -> ok after 5000 -> ok end,
        receive {task_done, 2, _} -> ok after 5000 -> ok end,
        receive {task_done, 3, _} -> ok after 5000 -> ok end,
        receive {waiter_done, _} -> ok after 5000 -> ok end,

        timer:sleep(100),

        %% Back to Ready
        S4 = puddle:status(M, 1000),
        io:format("status4=~p~n", [S4]),
        {pool_status, ready, 3, 3, 0, 0} = S4,

        puddle:shutdown(M),
        timer:sleep(50),
        io:format("PASS: pool status reports correct state and counts~n"),
        halt(0)
    catch
        Class:Reason:ST ->
            io:format("ERROR: ~p:~p~n~p~n", [Class, Reason, ST]),
            halt(2)
    end.
