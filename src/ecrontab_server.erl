-module(ecrontab_server).
-behaviour(gen_server).
-include("ecrontab.hrl").
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([
    start_link/0,
    add/2,
    remove/2
]).

-record(state, {now_seconds, tid}).
-record(server_task, {name, spec, mfa, options}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link(?MODULE, [], []).

add(Pid, Task) ->
    gen_server:call(Pid, {add, Task}).%todo infinity

remove(Pid, Task) ->
    gen_server:cast(Pid, {remove, Task}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    pg2:join(?GROUP_NAME, self()),
    Tid = ecrontab_task_manager:reg_server(self()),%todo is remove tid
    NowSeconds = calendar:datetime_to_gregorian_seconds(erlang:localtime()),
    {ok, #state{tid = Tid,now_seconds = NowSeconds}}.

handle_call({add, Task}, _From, State) ->
    {reply, do_add(Task, State#state.now_seconds), State};
handle_call(_Msg, _From, State) ->
    {reply, noknow, State}.

handle_cast({remove, Task}, State) ->
    do_remove(State#state.now_seconds, Task),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({ecrontab_tick, Seconds}, State) ->
    do_tick(Seconds),
    {noreply, State#state{now_seconds = Seconds}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    ecrontab_task_manager:unreg_server(State#state.tid),
    ok.

code_change(_Old, State, _Extra) ->
    {ok, State}.
    
%% ====================================================================
%% internal API
%% ====================================================================

do_tick(NowSeconds) ->
    case erlang:erase(NowSeconds) of
        undefined ->
            ok;
        [] ->
            ok;
        STasks ->
            NowDatetime = calendar:gregorian_seconds_to_datetime(NowSeconds),
            loop_tasks(NowDatetime,STasks)
    end.

loop_tasks(_,[]) ->
    ok;
loop_tasks(NowDatetime, [STask|STasks]) ->
    do_spawn_task(STask#server_task.mfa),
    case ecrontab_next_time:next_seconds(STask#server_task.spec, NowDatetime) of
        {ok, NextSeconds} ->
            put_in_list(NextSeconds,STask);
        _ ->
            ecrontab_task_manager:task_over(STask#task.name)
    end,
    loop_tasks(NowDatetime, STasks).

do_spawn_task({M,F,A}) ->
    erlang:spawn(M, F, A);
do_spawn_task(Fun) ->
    erlang:spawn(Fun).

do_add(Task, NowSeconds) ->
    NowDatetime = calendar:gregorian_seconds_to_datetime(NowSeconds),
    case ecrontab_next_time:next_seconds(Task#task.spec, NowDatetime) of
        {ok, NextSeconds} ->
            STask = task_to_server_task(Task),
            put_in_list(NextSeconds,STask),
            ok;
        Err ->
            Err
    end.

task_to_server_task(Task) ->
    #server_task{name = Task#task.name, spec = Task#task.spec, mfa = Task#task.mfa, options = Task#task.options}.

put_in_list(Seconds,STask) ->
    List =
    case get(Seconds) of
        undefined ->
            [STask];
        List0 ->
            [STask|List0]
    end,
    put(Seconds, List).

do_remove(NowSeconds, Task) ->
    NowDatatime = calendar:gregorian_seconds_to_datetime(NowSeconds),
    case ecrontab_next_time:next_seconds(Task#task.spec, NowDatatime) of
        {ok, NextSeconds} ->
            erlang:erase(NextSeconds);
        _ ->
            none
    end.