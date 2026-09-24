#!/usr/bin/env escript
%% Test: pool exhaustion and recovery with builder API
%% Start a pool with 2 resources. Spawn 2 tasks that hold resources for 800ms.
%% Verify a 3rd checkout fails. Wait for tasks, verify a 4th checkout succeeds.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        Builder = puddle:size(puddle:new(fun() -> {ok, 1} end), 2),
        {ok, M} = puddle:start(Builder, 5000),
        Self = self(),

        %% Spawn 2 tasks that hold resources for 800ms
        spawn(fun() ->
            R = (catch puddle:apply(M, fun(N) -> timer:sleep(800), puddle:keep(N) end, 5000, fun(X) -> X end)),
            Self ! {task1, R}
        end),
        spawn(fun() ->
            R = (catch puddle:apply(M, fun(N) -> timer:sleep(800), puddle:keep(N) end, 5000, fun(X) -> X end)),
            Self ! {task2, R}
        end),

        timer:sleep(100),

        %% 3rd checkout should fail immediately
        ExhaustResult = (catch puddle:apply(M, fun(N) -> puddle:keep(N) end, 200, fun(X) -> X end)),

        receive {task1, _} -> ok after 5000 -> error(task1_timeout) end,
        receive {task2, _} -> ok after 5000 -> error(task2_timeout) end,

        timer:sleep(300),

        %% 4th checkout should succeed
        RecoverResult = (catch puddle:apply(M, fun(N) -> puddle:keep(N) end, 3000, fun(X) -> X end)),
        puddle:shutdown(M),
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
