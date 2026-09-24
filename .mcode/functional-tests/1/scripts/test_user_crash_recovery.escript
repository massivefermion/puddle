#!/usr/bin/env escript
%% Test: user process crash recovery
%% Start a pool with 1 resource. Spawn a process that uses the resource
%% successfully but then crashes (panics). Verify the pool recovers and the
%% resource can be used again.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        {ok, M} = puddle:start(1, fun() -> {ok, 8} end, 5000),

        %% Spawn a process that uses the resource then panics
        Pid = spawn(fun() ->
            puddle:apply(M, fun(N) -> N end, 2000, fun(_R) ->
                %% Crash after the resource operation completes
                error(user_panic)
            end)
        end),

        %% Wait for the spawned process to crash
        Ref = monitor(process, Pid),
        receive
            {'DOWN', Ref, process, Pid, _Reason} -> ok
        after 5000 ->
            io:format("ERROR: user process did not crash~n"),
            halt(2)
        end,

        %% Give pool time to process the user's ProcessDown
        timer:sleep(300),

        %% Try to use the pool again
        RecoverResult = (catch puddle:apply(M, fun(N) -> N end, 3000, fun(X) -> X end)),
        puddle:shutdown(M, fun(_) -> nil end),
        timer:sleep(50),

        io:format("recover=~p~n", [RecoverResult]),
        case RecoverResult of
            {ok, 8} ->
                io:format("PASS: pool recovered after user crash~n"),
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
