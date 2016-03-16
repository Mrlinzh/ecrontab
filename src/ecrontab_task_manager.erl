-module(ecrontab_task_manager).
-behaviour(gen_server).
-include("ecrontab.hrl").
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([
    start_link/0,
    tick/1,
    add/4, add/5,
    remove/2,
    reg_server/1,
    unreg_server/1,
    task_over/1
]).

-define(SERVER, ?MODULE).
-record(state, {server_ets_name_counter=0,servers=[],unlive_servers=[]}).%servers todo use gbtree
-record(server, {pid,tid,task_count=0}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

tick(Seconds) ->
    gen_server:cast(?SERVER, {ecrontab_tick, Seconds}).

%% add/4
add(Name, Spec, MFA, Options) ->
    NowDatetime = erlang:localtime(),
    add_do(Name, Spec, MFA, NowDatetime, Options).

%% add/5
add(undefined, Spec, MFA, NowDatetime, Options) ->
    Name = erlang:unique_integer(),
    add_do(Name, Spec, MFA, NowDatetime, Options);
add(Name, Spec, MFA, NowDatetime, Options) ->
    add_do(Name, Spec, MFA, NowDatetime, Options).

add_do(Name, Spec, MFA, NowDatetime, Options) ->
    Task = #task{name = Name, spec = Spec, mfa = MFA, add_time = NowDatetime, options = Options},
    case gen_server:call(?SERVER, {add, Task}, infinity) of
        ok ->
            {ok, Name};
        Err ->
            Err
    end.

remove(Name, Options) ->
    gen_server:call(?SERVER, {remove, {Name, Options}}).

reg_server(Pid) ->
    gen_server:call(?SERVER, {reg_server, Pid}).

unreg_server(Pid) ->
    gen_server:cast(?SERVER, {unreg_server, Pid}).

task_over(Name) ->
    gen_server:cast(?SERVER, {task_over, Name}).
%%already_exists


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    ets:new(?ETS_NAME_TASK_INDEX,[
        named_table,
        {keypos,#task_index.name},
        {write_concurrency, true},
        {read_concurrency, true}]),
    {ok, #state{}}.

handle_call({add, Task}, _From, State) ->
    case do_add(Task, State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        Reply ->
            {reply, Reply, State}
    end;
handle_call({remove, {Name, Options}}, _From, State) ->
    case do_remove(Name, Options, State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        Reply ->
            {reply, Reply, State}
    end;
handle_call({reg_server, Pid}, _From, State) ->
    case State#state.unlive_servers of
        [] ->
            Counter = State#state.server_ets_name_counter+1,
            Tid = new_server_ets(Counter),
            Servers = sort_servers([#server{pid = Pid,tid = Tid}|State#state.servers]),
            {reply, Tid, State#state{server_ets_name_counter = Counter,servers = Servers}};
        [Server|UnliveServers] ->
            Tid = Server#server.tid,
            Servers = sort_servers([Server#server{pid = Pid}|State#state.servers]),
            {reply, Tid, State#state{servers = Servers, unlive_servers = UnliveServers}}
    end;
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({unreg_server, Tid}, State) ->
    Servers0 = State#state.servers,
    case lists:keytake(Tid, #server.tid, Servers0) of
        false ->
            {noreply, State};
        {value, Server, Servers2} ->
            UnliveServers = [Server#server{pid = undefined}|State#state.unlive_servers],
            {noreply, State#state{servers = Servers2,unlive_servers = UnliveServers}}
    end;
handle_cast({task_over, Name}, State) ->
    {ok, NewState} = do_task_over(Name, State),
    {noreply, NewState};
handle_cast({ecrontab_tick, _Seconds}, State) ->
    %todo other use
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

new_server_ets(N) ->
    ets:new(erlang:binary_to_atom(<<"ets_tasks_",(integer_to_binary(N))/binary>>, utf8),
        [
            {keypos,#task.name},
            {write_concurrency, true},
            {read_concurrency, true}
        ]).

sort_servers(Servers) ->
    lists:keysort(#server.task_count, Servers).

do_add(Task, State) ->
    case State#state.servers of
        [Server|Servers] when Server#server.task_count < ?ONE_PROCESS_MAX_TASKS_COUNT ->
            Tid = Server#server.tid,
            case ets:insert_new(?ETS_NAME_TASK_INDEX, #task_index{name = Task#task.name,tid = Tid}) of
                true ->
                    case ecrontab_server:add(Server#server.pid, Task) of
                        ok ->
                            ets:insert(Tid, Task),
                            NewServer = Server#server{task_count = Server#server.task_count + 1},
                            NewServers = sort_servers([NewServer|Servers]),
                            {ok, State#state{servers = NewServers}};
                        Err ->
                            ets:delete(?ETS_NAME_TASK_INDEX, Task#task.name),
                            Err
                    end;
                false ->
                    {error, task_exists}
            end;
        [] ->
            {error, no_server_use}
    end.

do_remove(Name, _Options, State) ->
    case ets:lookup(?ETS_NAME_TASK_INDEX, Name) of
        [TaskIndex] ->
            ets:delete(?ETS_NAME_TASK_INDEX, Name),
            Tid = TaskIndex#task_index.tid,
            [Task] = ets:lookup(Tid, Name),
            ets:delete(Tid, Name),
            case lists:keytake(Tid, #server.tid, State#state.servers) of
                {value, Server, Servers0} ->
                    ecrontab_server:remove(Server#server.pid, Task),
                    Servers = sort_servers([Server#server{task_count = Server#server.task_count-1}|Servers0]),
                    {ok, State#state{servers = Servers}};
                false ->
                    UnliveServers = lists:keydelete(Tid, #server.tid, State#state.unlive_servers),
                    {ok, State#state{unlive_servers = UnliveServers}}
            end;
        []  ->
            {error, no_such_task}
    end.

do_task_over(Name, State) ->
    case ets:lookup(?ETS_NAME_TASK_INDEX, Name) of
        [TaskIndex] ->
            ets:delete(?ETS_NAME_TASK_INDEX, Name),
            Tid = TaskIndex#task_index.tid,
            ets:delete(Tid, Name),
            case lists:keytake(Tid, #server.tid, State#state.servers) of
                {value, Server, Servers0} ->
                    Servers = sort_servers([Server#server{task_count = Server#server.task_count-1}|Servers0]),
                    {ok, State#state{servers = Servers}};
                false ->
                    UnliveServers = lists:keydelete(Tid, #server.tid, State#state.unlive_servers),
                    {ok, State#state{unlive_servers = UnliveServers}}
            end;
        []  ->
            {ok, State}
    end.