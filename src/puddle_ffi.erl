-module(puddle_ffi).

-export([start_port/1, send_to_port/2, get_response/0]).

start_port(Arg) -> open_port({spawn, Arg}, [binary]).

send_to_port(Port, Cmd) -> Port ! {self(), Cmd}.

get_response() ->
    receive
        {_, Response} -> Response
    end.
