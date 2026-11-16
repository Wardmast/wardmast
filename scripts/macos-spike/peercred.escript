#!/usr/bin/env escript
%% LOCAL_PEERCRED / LOCAL_PEERPID on an accepted unix-socket connection, read
%% via inet:getopts raw. macOS: SOL_LOCAL=0, LOCAL_PEERCRED=1 (struct xucred,
%% 76 bytes: u32 version, u32 uid, i16 ngroups, pad, u32 groups[16]),
%% LOCAL_PEERPID=2 (int).
main([Dir]) ->
    Path = filename:join(Dir, "peercred.sock"),
    _ = file:delete(Path),
    {ok, L} = gen_tcp:listen(0, [{ifaddr, {local, Path}}, binary, {active, false}]),
    Self = self(),
    spawn_link(fun() ->
        {ok, C} = gen_tcp:connect({local, Path}, 0, [binary, {active, false}]),
        Self ! {client, C},
        receive stop -> ok end
    end),
    {ok, S} = gen_tcp:accept(L, 5000),
    {ok, [{raw, 0, 1, Cred}]} = inet:getopts(S, [{raw, 0, 1, 76}]),
    io:format("raw xucred: ~p~n", [Cred]),
    <<_Ver:32/native, Uid:32/native, _/binary>> = Cred,
    PidRes = inet:getopts(S, [{raw, 0, 2, 4}]),
    io:format("peerpid raw: ~p~n", [PidRes]),
    {ok, [{raw, 0, 2, PidBin}]} = PidRes,
    <<Pid:32/native-signed>> = PidBin,
    io:format("uid=~p pid=~p (this beam pid=~s)~n", [Uid, Pid, os:getpid()]),
    case {Uid =:= list_to_integer(string:trim(os:cmd("id -u"))),
          Pid =:= list_to_integer(os:getpid())} of
        {true, true} -> io:format("RESULT ok~n");
        {true, false} -> io:format("RESULT pid-mismatch~n");
        _ -> io:format("RESULT uid-mismatch~n")
    end;
main(_) ->
    io:format("usage: peercred.escript <dir>~n"), halt(2).
