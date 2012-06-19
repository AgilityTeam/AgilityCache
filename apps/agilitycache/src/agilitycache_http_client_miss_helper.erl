-module(agilitycache_http_client_miss_helper).

-behaviour(gen_server).

%% API
-export([start_link/0, start/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).

-export([open/2,
         write/2,
         close/1]).

-record(state, {
      file_id = <<>> :: binary(),
      file_path = <<>> :: binary(),
      file_handle = undefined :: file:io_device() | undefined
      }).

%%%===================================================================
%%% API
%%%===================================================================
-spec open(_,atom() | pid() | {atom(),_} | {'via',_,_}) -> 'ok'.
open(FileId, Pid) ->
  gen_server:cast(Pid, {open, FileId}).
-spec write(_,atom() | pid() | {atom(),_} | {'via',_,_}) -> 'ok'.
write(Data, Pid) ->
  gen_server:cast(Pid, {write, Data}).
-spec close(atom() | pid() | {atom(),_} | {'via',_,_}) -> 'ok'.
close(Pid) ->
  gen_server:cast(Pid, close).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> 'ignore' | {'error',_} | {'ok',pid()}.
start_link() ->
        gen_server:start_link(?SERVER, [], []).

-spec start() -> 'ignore' | {'error',_} | {'ok',pid()}.
start() ->
  gen_server:start(?SERVER, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec init(_) -> {ok, #state{}}.
init([]) ->
        {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec handle_call(_,_,_) -> {'reply','ok',_}.
handle_call(_Request, _From, State) ->
        Reply = ok,
        {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(_,_) -> {'noreply',_} | {'stop',{'error',atom()},#state{}}.
handle_cast({open, FileId}, State) ->
  try
    {ok, Path} = agilitycache_cache_dir:get_best_filepath(FileId),
    filelib:ensure_dir(Path),
    {ok, FileHandle} = file:open(<<Path/binary, ".tmp" >>, [raw, write, delayed_write, binary]),
    {ok, Path, FileHandle}
  of
    {ok, Path0, FileHandle0} ->
      lager:debug("Path: ~p", [Path0]),
      lager:debug("FileHandle: ~p", [FileHandle0]),
      {noreply, State#state{file_handle=FileHandle0, file_path=Path0}}
  catch
        error:Reason ->
          {stop, {error, Reason}, State#state{file_handle=undefined}}
  end;
handle_cast({write, _}, State = #state{file_handle=undefined}) ->
  {stop, {error, notopen}, State};
handle_cast({write, Data}, State = #state{file_handle=FileHandle}) ->
  case file:write(FileHandle, Data) of
    ok ->
      {noreply, State};
    {error, _} = Z ->
      {stop, Z, State}
  end;
handle_cast(close, State = #state{file_path=FileName}) ->
  close_file(State),
  file:rename(<<FileName/binary, ".tmp">>, FileName),
  {stop, normal, State#state{file_handle=undefined}};

handle_cast(_Msg, State) ->
        {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec handle_info(_,_) -> {'noreply',_}.
handle_info(_Info, State) ->
        {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec terminate(_,#state{}) -> 'ok'.
terminate(Reason, State) ->
  close_file(State),
  lager:debug("Reason: ~p", [Reason]),
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec code_change(_,_,_) -> {'ok',_}.
code_change(_OldVsn, State, _Extra) ->
        {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec close_file(#state{}) -> 'ok'.
close_file(#state{file_handle=undefined}) ->
  ok;
close_file(#state{file_handle=FileHandle}) ->
  lager:debug("Fechando: ~p", [FileHandle]),
  %% Faz duaz vezes para evitar erro de delayed write
  file:close(FileHandle),
  file:close(FileHandle),
  ok.
