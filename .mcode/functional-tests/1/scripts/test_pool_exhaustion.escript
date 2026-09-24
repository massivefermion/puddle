#!/usr/bin/env escript
%% Test: pool exhaustion and recovery
%% Start a pool with 2 resources. Spawn 2 tasks that hold resources for 1 second.
%% Verify a 3rd checkout fails (pool exhausted). Wait for tasks to finish.
%% Verify a 4th checkout succeeds (resources returned).
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        {ok, M} = puddle:start(2, fun() -> {ok, 1} end, 5000),
        Self = self(),

        %% Spawn 2 tasks that hold resources for 800ms
        spawn(fun() ->
            R = (catch puddle:apply(M, fun(N) -> timer:sleep(800), N end, 5000, fun(X) -> X end)),
            Self ! {task1, R}
        end),
        spawn(fun() ->
            R = (catch puddle:apply(M, fun(N) -> timer:sleep(800), N end, 5000, fun(X) -> X end)),
            Self ! {task2, R}
        end),

        %% Wait for both to check out resources
        timer:sleep(100),

        %% 3rd checkout should fail immediately (pool exhausted)
        ExhaustResult = (catch puddle:apply(M, fun(N) -> N end, 200, fun(X) -> X end)),

        %% Wait for the first 2 tasks to complete
        receive {task1, _} -> ok after 5000 -> error(task1_timeout) end,
        receive {task2, _} -> ok after 5000 -> error(task2_timeout) end,

        %% Give pool time to process ProcessDown events
        timer:sleep(300),

        %% 4th checkout should succeed
        RecoverResult = (catch puddle:apply(M, fun(N) -> N end, 3000, fun(X) -> X end)),
        puddle:shutdown(M, fun(_) -> nil end),
        timer:sleep(50),

        io:format("exhaust=~p recover=~p~n", [ExhaustResult, RecoverResult]),
        case {ExhaustResult, RecoverResult} of
            {{error, _}, {ok, 1}} ->
                io:format("PASS: pool exhaustion and recovery~n"),
                halt(0);
            _ ->
                io:format("FAIL: unexpected results~n"),
                halt(1)
        end
    catch
        Class:Reason:ST ->
            io:format("ERROR: ~p:~p~n~p~n", [Class, Reason, ST]),
            halt(2)
    end.
