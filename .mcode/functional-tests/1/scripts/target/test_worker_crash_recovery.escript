#!/usr/bin/env escript
%% Test: worker crash recovery with builder API
%% Start a pool with 1 resource. Crash the worker via a panic function.
%% Verify the pool replaces the crashed worker and recovers.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        Builder = puddle:size(puddle:new(fun() -> {ok, 8} end), 1),
        {ok, M} = puddle:start(Builder, 5000),
        Self = self(),

        %% Spawn a process that crashes the worker
        spawn(fun() ->
            R = (catch puddle:apply(M, fun(_) -> error(deliberate_crash) end, 2000, fun(X) -> X end)),
            Self ! {crash_done, R}
        end),

        receive
            {crash_done, CrashResult} ->
                io:format("crash_result=~p~n", [CrashResult])
        after 10000 ->
            io:format("ERROR: crash task timed out~n"),
            halt(2)
        end,

        timer:sleep(500),

        %% Try to use the pool again
        RecoverResult = (catch puddle:apply(M, fun(N) -> puddle:keep(N) end, 3000, fun(X) -> X end)),
        puddle:shutdown(M),
        timer:sleep(50),

        io:format("recover=~p~n", [RecoverResult]),
        case RecoverResult of
            {ok, 8} ->
                io:format("PASS: pool recovered after worker crash~n"),
                halt(0);
            Other ->
                io:format("FAIL: expected {ok, 8}, got ~p~n", [Other]),
                halt(1)
        end
    catch
        Class:Reason:ST ->
            io:format("ERROR: ~p:~p~n~p~n", [Class, Reason, ST]),
            halt(2)
    end.
