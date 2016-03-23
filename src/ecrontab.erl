-module(ecrontab).
-include("ecrontab.hrl").
-export([
    start/0,
    stop/0,
    add/3, add/4,
    remove/1, remove/2,
    add_server/0,
    get_server_count/0
]).

%% for test
-export([
    app_performance_test/2,

    next_time_performance_test/1,
    loop_next_time/2, loop_next_time/3,
    loop_next_time_do/3
]).

%% ====================================================================
%% app
%% ====================================================================

start() ->
    application:ensure_all_started(?MODULE).

stop() ->
    application:stop(?MODULE).

%% ====================================================================
%% API
%% ====================================================================

add(Name, Spec, MFA) ->
    add(Name, Spec, MFA, []).
add(Name, Spec0, {M,F,A}=MFA, Options) when is_atom(M) andalso is_atom(F) andalso is_list(A) ->
    do_add(Name, Spec0, MFA, Options);
add(Name, Spec0, {_Node,M,F,A}=MFA, Options) when is_atom(M) andalso is_atom(F) andalso is_list(A) ->
    do_add(Name, Spec0, MFA, Options);
add(Name, Spec0, Fun, Options) when is_function(Fun, 0) ->
    do_add(Name, Spec0, Fun, Options).

do_add(Name, Spec0, MFA, Options) when is_list(Options) ->
    NowDatetime = erlang:localtime(),
    case ecrontab_parse:parse_spec(Spec0, [{filter_over_time,NowDatetime}]) of
        {ok, Spec} ->
            ecrontab_task_manager:add(Name, Spec, MFA, NowDatetime, Options);
        Err ->
            Err
    end.

remove(Name) ->
    remove(Name, []).
remove(Name, Options) ->
    ecrontab_task_manager:remove(Name, Options).

add_server() ->
    ecrontab_server_sup:start_child().

get_server_count() ->
    proplists:get_value(workers, supervisor:count_children(ecrontab_server_sup)).

%% ====================================================================
%% app performance test
%% ====================================================================
app_performance_test(Count,Secs) when Secs > 0 andalso Secs < 60 ->
    ecrontab:start(),
    eprof:start(),
    Self = self(),
    eprof:profile([Self]),
    MaxTaskCount = ecrontab_server:min_server_count() * ?ONE_PROCESS_MAX_TASKS_COUNT,
    if
        Count > MaxTaskCount ->
            AddChildCount0 = (Count - MaxTaskCount) / ?ONE_PROCESS_MAX_TASKS_COUNT,
            AddChildCount1 = erlang:trunc(AddChildCount0),
            AddChildCount =
            case AddChildCount0 - AddChildCount1 == 0 of
                true ->
                    AddChildCount1;
                _ ->
                    AddChildCount1+1
            end,
            [add_server()||_ <- lists:seq(1,AddChildCount)];
        true ->
            none
    end,
    Datetime = erlang:localtime(),
    SecList = app_performance_test_get_sec_list(Secs,Datetime,[]),
    [{ok, Name} = ecrontab:add(Name,{'*','*','*','*','*','*',SecList},fun() -> ok end) ||
        Name <- lists:seq(1,Count)],
    io:format("add spec ok~n"),
    timer:sleep(Secs*1000),
    ecrontab:stop(),
    eprof:stop_profiling(),
    eprof:analyze(),
    eprof:stop().

app_performance_test_get_sec_list(0,_,List) ->
    List;
app_performance_test_get_sec_list(Secs,NowDatetime,List) ->
    Datetime = ecrontab_time_util:next_second(NowDatetime),
    Sec = ecrontab_time_util:get_datetime_second(Datetime),
    app_performance_test_get_sec_list(Secs-1,Datetime,[Sec|List]).

%% ====================================================================
%% next_time performance test
%% ====================================================================

next_time_performance_test(Count) ->
    eprof:start(),
    eprof:profile([self()]),
    Tests =[
        {'*', '*', '*', '*', '*', [5,15], 0},
        {'*', '*', '*', '*', '*', '*', 0}
    ],
    [loop_next_time(Spec,Count) || Spec<-Tests],
    eprof:stop_profiling(),
    eprof:analyze(),
    eprof:stop().

loop_next_time(Spec,Count) ->
    NowDatetime = {{2016,3,7},{22,2,39}},
    loop_next_time(Spec,NowDatetime,Count).
loop_next_time(Spec0,NowDatetime,Count) ->
    {ok, Spec} = ecrontab_parse:parse_spec(Spec0, []),
    {Time,_} = timer:tc(?MODULE,loop_next_time_do,[Spec,NowDatetime,Count]),
    Ptime = Time/Count,
    Times = 1000000/Ptime,
    io:format("Spec0:~p,Count:~p,tc Time:~ps,per count time:~pus,one sec times:~p~n",[Spec0,Count,Time/1000000,Ptime,Times]).

loop_next_time_do(Spec,NowDatetime,1) ->
    ecrontab_next_time:next_time(Spec,NowDatetime),
    ok;
loop_next_time_do(Spec,NowDatetime,N) ->
    case ecrontab_next_time:next_time(Spec,NowDatetime) of
        {ok, Datetime} ->
            loop_next_time_do(Spec,Datetime,N-1);
        Err ->
            Err
    end.