-module(agilitycache_database_srv).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("include/cache.hrl").

-export([read_cached_file_info/2,
    write_cached_file_info/3]).

-define(APPLICATION, agilitycache).

-record(state, {}).

%% Synchronous call
read_cached_file_info(Pid, FileId) ->
    gen_server:call(Pid, {read_cached_file_info, FileId}).

%% This call is asynchronous
write_cached_file_info(Pid, FileId, CachedFileInfo) ->
      gen_server:cast(Pid, {write_cached_file_info, FileId, CachedFileInfo}).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
        gen_server:start_link(?MODULE, [], []).

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
handle_call({read_cached_file_info, FileId}, _From, _State) ->
 do_read_cached_file_info(FileId); 
handle_call(_Request, _From, State) ->
        Reply = ok,
        {reply, Reply, State}.

do_read_cached_file_info(_FileId) ->
  ok.

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
terminate(_Reason, _State) ->
        ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
        {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%-spec find_file(binary(), binary())
%% FileId is a md5sum in binary format
%% Devo aceitar mais de uma localização?
find_file(FileId, Extension) ->
  Paths = application:get_env(?APPLICATION, database),
  SubPath = get_subpath(FileId),
  FilePaths = lists:map(fun(X) -> filename:join([X, <<SubPath/binary, Extension/binary>>]) end, Paths),
  FoundPaths = [FileFound || FileFound <- FilePaths, filelib:is_regular(FileFound)],
  case FoundPaths of 
    [] ->
      {error, notfound};
    _ ->
      erlang:hd(FoundPaths)
  end.

get_subpath(FileId) ->
  HexFileId = list_to_binary(hexstring(FileId)),
  filename:join([binary:at(HexFileId, 1), binary:at(HexFileId, 20), HexFileId]).

hexstring(<<X:128/big-unsigned-integer>>) ->
  lists:flatten(io_lib:format("~32.16.0B", [X])).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
get_subpath_test_() ->
  %% FileId, Subpath
  Tests = [
    {<<144,1,80,152,60,210,79,176,214,150,63,125,40,225,127,114>>, <<"0/6/900150983cd24fb0d6963f7d28e17f72">>}
  ],
  [{H, fun() -> R = get_subpath(H) end} || {H, R} <- Tests].
-endif.
          
