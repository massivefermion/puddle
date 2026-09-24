#!/usr/bin/env escript
%% Test: user process crash recovery with builder API
%% Start a pool with 1 resource. Spawn a process that uses the resource
%% successfully but then crashes. Verify the pool recovers.
main(_) ->
    code:add_paths(filelib:wildcard("build/dev/erlang/*/ebin")),
    try
        Builder = puddle:size(puddle:new(fun() -> {ok, 8} end), 1),
        {ok, M} = puddle:start(Builder, 5000),

        Pid = spawn(fun() ->
            puddle:apply(M, fun(N) -> puddle:keep(N) end, 2000, fun(_R) ->
                error(user_panic)
            end)
        end),

        Ref = monitor(process, Pid),
        receive
            {'DOWN', Ref, process, Pid, _Reason} -> ok
        after 5000 ->
            io:format("ERROR: user process did not crash~n"),
            halt(2)
        end,

        timer:sleep(300),

        RecoverResult = (catch puddle:apply(M, fun(N) -> puddle:keep(N) end, 3000, fun(X) -> X end)),
        puddle:shutdown(M),
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
