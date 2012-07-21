%% This file is part of AgilityCache, a web caching proxy.
%%
%% Copyright (C) 2011, 2012 Joaquim Pedro França Simão
%%
%% AgilityCache is free software: you can redistribute it and/or modify
%% it under the terms of the GNU Affero General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% AgilityCache is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU Affero General Public License for more details.
%%
%% You should have received a copy of the GNU Affero General Public License
%% along with this program.  If not, see <http://www.gnu.org/licenses/>.

-module(agilitycache_srv).

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

-define(SERVER, ?MODULE).

-record(state, {listener}).

-include("cache.hrl").

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
-spec start_link() -> 'ignore' | {'error',_} | {'ok',pid()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

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
-spec init([]) -> {'ok',#state{listener::reference()}}.
init([]) ->
    start_metrics(),
    start_tables(),
    %% list({Handler, Opts})
    Dispatch = [{agilitycache_proxy_handler, []}],
    %% Name, NbAcceptors, Transport, TransOpts, Protocol, ProtoOpts
    Ref = make_ref(),
    ListenOpts = agilitycache_utils:get_app_env(agilitycache, listen, []),
    BufferSize = agilitycache_utils:get_app_env(agilitycache, buffer_size, 87380),
    Timeout = agilitycache_utils:get_app_env(agilitycache, tcp_timeout, 5000),
    %%lager:debug("ListenOpts ~p~n", [ListenOpts]),
    TransOpts = [
                 {port, proplists:get_value(port, ListenOpts, 8080)},
                 %% We don't care if we have logs of pending connections, we'll process them anyway
                 {backlog, proplists:get_value(backlog, ListenOpts, 128000)},
                 {max_connections, proplists:get_value(max_connections, ListenOpts, 4096)},
                 %%{nodelay, true}, %% We want to be informed even when packages are small
                 {reuseaddr, true},
                 %% If we couldn't send a message in Timeout time, something is definitively wrong...
                 {send_timeout, Timeout},
                 %%... and therefore the connection should be closed
                 {send_timeout_close, true},
                 {buffer, BufferSize}
                ],
    lager:debug("TransOpts~p~n", [TransOpts]),
    NbAcceptors = proplists:get_value(acceptors, ListenOpts),
    lager:debug("NbAcceptors: ~p~n", [NbAcceptors]),
    {ok, _} = cowboy:start_listener(Ref, NbAcceptors,
                                    agilitycache_tcp_transport, TransOpts,
                                    agilitycache_http_session, [{dispatch, Dispatch}]
                                   ),
    {ok, #state{listener=Ref}}.

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
-spec handle_cast(_,_) -> {'noreply',_}.
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
-spec terminate(_,#state{}) -> any().
terminate(_Reason, #state{listener=Listener}) ->
    cowboy:stop_listener(Listener).

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

-spec start_metrics() -> any().
start_metrics() ->
    folsom_sup:start_link(),
    folsom_metrics:new_meter(requests),
    folsom_metrics:new_histogram(resolve_time, none, infinity),
    folsom_metrics:new_histogram(connection_time, none, infinity),
    folsom_metrics:new_histogram(total_proxy_time, none, infinity).

start_tables() ->
    mnesia:start(),
    mnesia:create_table(agilitycache_transit_file_reading, [{ram_copies, [node()]},
                                                            {attributes, record_info(fields, agilitycache_transit_file_reading)},
                                                            {type, bag}]),
    mnesia:create_table(agilitycache_transit_file_downloading, [{ram_copies, [node()]},
                                                                {attributes, record_info(fields, agilitycache_transit_file_downloading)}]).
