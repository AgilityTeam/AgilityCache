-module(agilitycache_http_client).

-behaviour(gen_server).
-export([init/1, 
	handle_call/3, 
	handle_cast/2, 
	handle_info/2, 
	terminate/2, 
	code_change/3]).

-export([start_link/3]).

-export([start_request/2, 
	start_keepalive_request/2, 
	start_receive_reply/1, 
	get_http_rep/1, 
	set_http_rep/2, 
	get_body/1, 
	send_data/2, 
	end_reply/1, 
	stop/1]).
-export([get_socket/2, set_socket/2]).

-include("cache.hrl"). %% superseeds http.hrl

-record(state, {
          http_rep :: #http_rep{},
          client_socket :: inet:socket(),
          transport :: module(),
          rep_empty_lines = 0 :: integer(),
          max_empty_lines :: non_neg_integer(),
          timeout = 5000 :: timeout(),
          client_buffer = <<>> :: binary(),
          cache_plugin = agilitycache_cache_plugin_default :: module(),
          cache_status = undefined :: undefined | miss | hit,
          cache_id = <<>> :: binary(),
          cache_info = #cached_file_info{} :: #cached_file_info{},
          cache_file_path = <<>> :: binary(),
          cache_file_helper = undefined :: pid(), %% Que tipo usar para um pid que não dê pau no dialyzer?
          cache_file_handle,
          cache_http_req %% Only set and used when cache_status = miss
         }).

start_link(Transport, Timeout, MaxEmptyLines) ->
	gen_server:start_link(?MODULE, [Transport, Timeout, MaxEmptyLines], []).

init([Transport, Timeout, MaxEmptyLines]) ->
	{ok, #state{timeout=Timeout, max_empty_lines=MaxEmptyLines, transport=Transport}}.

%% Public API
%% ===============================================================
start_request(Pid, HttpReq) ->
	gen_server:call(Pid, {start_request, HttpReq}, infinity).

start_keepalive_request(Pid, HttpReq) ->
	gen_server:call(Pid, {start_keepalive_request, HttpReq}, infinity).

start_receive_reply(Pid) ->
	gen_server:call(Pid, start_receive_reply, infinity).

get_http_rep(Pid) ->
	gen_server:call(Pid, get_http_rep, infinity).

set_http_rep(Pid, HttpRep) ->
	gen_server:call(Pid, {set_http_rep, HttpRep}, infinity).

get_body(Pid) ->
	gen_server:call(Pid, get_body, infinity).

send_data(Pid, Data) ->
	gen_server:call(Pid, {send_data, Data}, infinity).

end_reply(Pid) ->
	gen_server:call(Pid, end_reply, infinity).

stop(Pid) ->
	gen_server:call(Pid, stop, infinity).

get_socket(Pid, OuterPid) ->
	gen_server:call(Pid, {get_socket, OuterPid}, infinity).

set_socket(Pid, Socket) ->
	gen_server:call(Pid, {set_socket, Socket}, infinity).

%% ===============================================================
handle_call({start_request, HttpReq}, _From, State) ->
	handle_start_request(HttpReq, State);
handle_call({start_keepalive_request, HttpReq}, _From, State) ->
	handle_start_keepalive_request(HttpReq, State);
handle_call(start_receive_reply, _From, State) ->
	handle_start_receive_reply(State);
handle_call(get_http_rep, _From, State) ->
	handle_get_http_rep(State);
handle_call({set_http_rep, HttpReq}, _From, State) ->
	handle_set_http_rep(HttpReq, State);	
handle_call(get_body, _From, State) ->
	handle_get_body(State);
handle_call({send_data, Data}, _From, State) ->
	handle_send_data(Data, State);
handle_call(end_reply, _From, State) ->
	handle_end_reply(State);
handle_call(stop, _From, State) ->
	handle_stop(State);
handle_call({get_socket, OtherPid}, _From, State) ->
	handle_get_socket(OtherPid, State);
handle_call({set_socket, Socket}, _From, State) ->
	handle_set_socket(Socket, State);	
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, #state{cache_status=CacheStatus, cache_id=FileId} = State) ->
	lager:debug("terminate Reason: ~p", [Reason]),
	lager:debug("Removendo índice do db: ~p", [FileId]),
	case CacheStatus of 
		miss ->	mnesia:transaction(fun() -> mnesia:delete({agilitycache_transit_file, FileId}), ok end);
		_ -> ok
	end,
	close_socket(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.                        

%% ==============================================

handle_get_socket(OtherPid, #state{client_socket = Socket, transport = Transport} = State) ->
	Transport:controlling_process(Socket, OtherPid),
	{reply, Socket, State}.

handle_set_socket(Socket, State) ->
	{reply, ok, State#state{client_socket=Socket}}.

handle_get_http_rep(#state{http_rep = HttpRep} = State) ->
	{reply, HttpRep, State}.

handle_set_http_rep(HttpRep, State) ->
	{reply, ok, State#state{http_rep = HttpRep}}.

handle_start_request(HttpReq, State) ->
	check_plugins(HttpReq, State, fun start_connect/2).

handle_start_keepalive_request(_HttpReq, State = #state{client_socket = undefined}) ->
	{stop, invalid_socket, {error, invalid_socket}, State};
handle_start_keepalive_request(HttpReq, State) ->
	check_plugins(HttpReq, State, fun start_send_request/2).

handle_start_receive_reply(State = #state{cache_status = hit, cache_info = CachedFileInfo,
                                               cache_id = FileId, cache_file_path=Path, cache_plugin = Plugin}) ->
	lager:debug("Cache Hit"),
	{ok, CachedFileInfo0} = agilitycache_database:read_remaining_info(FileId, CachedFileInfo),
	{ok, FileHandle} = file:open(Path, [raw, read, binary]),
	HttpRep = CachedFileInfo0#cached_file_info.http_rep,
	lager:debug("HttpRep: ~p", [HttpRep]),
	{reply, ok, State#state{cache_info = CachedFileInfo0, http_rep=HttpRep#http_rep{
		  headers = [{<<"X-Agilitycache">>, agilitycache_utils:hexstring(FileId)},
		             {<<"X-Cache">>, <<"Hit">>},
		             {<<"X-Plugin">>, Plugin:name()} |
		             HttpRep#http_rep.headers]}, cache_file_handle=FileHandle}};
handle_start_receive_reply(State) ->
	start_parse_reply(State).

%% Cache Hit functions
handle_get_body(State=#state{cache_status = hit, cache_file_handle=FileHandle}) ->
	case file:read(FileHandle, 8192) of
		{ok, Data} ->
			{reply, Data, State};
		eof ->
			{reply, <<>>, State}
	end;

%% Cache Miss functions

%% Empty buffer
handle_get_body(State=#state{
             client_socket=Socket, transport=Transport, timeout=T, client_buffer= <<>>, cache_status=miss, cache_file_helper=FileHelper})->
	{ok, Data} = Transport:recv(Socket, 0, T),
	agilitycache_http_client_miss_helper:write(Data, FileHelper),
	{reply, Data, State};
%% Non empty buffer
handle_get_body(State=#state{client_buffer=Buffer, cache_status=miss, cache_file_helper=FileHelper})->
	agilitycache_http_client_miss_helper:write(Buffer, FileHelper),
	{reply, Buffer, State#state{client_buffer = <<>>}};

%% No cache functions

%% Empty buffer
handle_get_body(State=#state{
             client_socket=Socket, transport=Transport, timeout=T, client_buffer= <<>>})->
	{ok, Data} = Transport:recv(Socket, 0, T),
	{reply, Data, State};
%% Non empty buffer
handle_get_body(State=#state{client_buffer=Buffer})->
	{reply, Buffer, State#state{client_buffer = <<>>}}.

handle_send_data(Data, State = #state { transport = Transport, client_socket = Socket } ) ->
	ok = Transport:send(Socket, Data),
	{reply, ok, State}.

handle_end_reply(State=#state{cache_status=hit, cache_file_handle=FileHandle, cache_info=CachedFileInfo, cache_id=FileId}) ->
	%% Salvando age
	agilitycache_database:write_info(FileId, CachedFileInfo#cached_file_info{age=calendar:universal_time()}),
	file:close(FileHandle),
	%% Removendo índice do db
	Fun1 = fun() ->
			       case mnesia:wread({agilitycache_transit_file, FileId}) of
				       [] ->
					       lager:debug("Mnesia WAT"),
					       ok;
				       [Record = #agilitycache_transit_file{ status = reading, concurrent_readers = CR}] when CR > 1 ->
					       mnesia:write(Record#agilitycache_transit_file{concurrent_readers = CR - 1}),
					       lager:debug("Mnesia concurrent_readers: ~p", [CR - 1]),
					       ok;
				       [_Record = #agilitycache_transit_file{ status = reading, concurrent_readers = 1}] ->
					       mnesia:delete({agilitycache_transit_file, FileId}),
					       ok;
				       Er32 ->
					       lager:debug("Mnesia error: ~p", [Er32]),
					       ok
			       end
	       end,
	mnesia:transaction(Fun1),
	{reply, ok, State#state{cache_status=undefined, cache_file_handle=undefined}};
handle_end_reply(State=#state{cache_status=miss, cache_file_helper=FileHelper, cache_id=FileId}) ->
	%% Removendo índice do db
	lager:debug("Removendo índice do db: ~p", [FileId]),
	mnesia:transaction(fun() -> mnesia:delete({agilitycache_transit_file, FileId}), ok end),
	agilitycache_http_client_miss_helper:close(FileHelper),
	{reply, ok, State#state{cache_status=undefined, cache_file_helper=undefined}};
handle_end_reply(State) ->
	{reply, ok, State}.

handle_stop(State) ->
	{stop, normal, ok, State#state{client_socket=undefined}}.

%%
%% Local Functions
%%

start_connect(HttpReq =
	              #http_req{ uri=_Uri=#http_uri{ domain = Host, port = Port}}, State=#state{transport = Transport, timeout = Timeout}) ->

	BufferSize = agilitycache_utils:get_app_env(agilitycache, buffer_size, 87380),
	TransOpts = [
	             %%{nodelay, true}%, %% We want to be informed even when packages are small
	             {send_timeout, Timeout}, %% If we couldn't send a message in Timeout time something is definitively wrong...
	             {send_timeout_close, true}, %%... and therefore the connection should be closed
	             {buffer, BufferSize},
	             {delay_send, true}
	            ],
	lager:debug("Host: ~p Port: ~p", [Host, Port]),
	{ok, Socket} = folsom_metrics:histogram_timed_update(connection_time,
	                                          Transport,
	                                          connect,
	                                          [binary_to_list(Host), Port, TransOpts, Timeout]),
	start_send_request(HttpReq, State#state{client_socket = Socket}).

start_send_request(HttpReq, State = #state{client_socket=Socket, transport=Transport}) ->
	%%lager:debug("ClientSocket buffer ~p,~p,~p",
	%%        [inet:getopts(Socket, [buffer]), inet:getopts(Socket, [recbuf]), inet:getopts(Socket, [sndbuf]) ]),
	Packet = agilitycache_http_req:request_head(HttpReq),
	lager:debug("Packet: ~p~n", [Packet]),
	lager:debug("HttpReq: ~p~n", [HttpReq]),
	ok = Transport:send(Socket, Packet),	
	{reply, HttpReq, State}.

start_parse_reply(State=#state{client_buffer=Buffer}) ->
	case erlang:decode_packet(http_bin, Buffer, []) of
		{ok, Reply, Rest} ->
			parse_reply({Reply, State#state{client_buffer=Rest}});
		{more, _Length} ->
			wait_reply(State)
	end.

wait_reply(State = #state{client_socket=Socket, transport=Transport, timeout=T, client_buffer=Buffer}) ->
	{ok, Data} = Transport:recv(Socket, 0, T),
	start_parse_reply(State#state{client_buffer= << Buffer/binary, Data/binary >>}).

parse_reply({{http_response, Version, Status, String}, State}) ->
	ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
	start_parse_reply_header(
	    State#state{http_rep=#http_rep{connection=ConnAtom, status=Status, version=Version, string=String}}
	   );
parse_reply({{http_error, <<"\r\n">>}, State=#state{rep_empty_lines=N, max_empty_lines=N}}) ->
	{stop, {http_error, 400}, {error, {http_error, 400}}, State};
parse_reply({_Data={http_error, <<"\r\n">>}, State=#state{rep_empty_lines=N}}) ->
	start_parse_reply(State#state{rep_empty_lines=N + 1}).

start_parse_reply_header(State=#state{client_buffer=Buffer}) ->
	case erlang:decode_packet(httph_bin, Buffer, []) of
		{ok, Header, Rest} ->
			parse_reply_header(Header, State#state{client_buffer=Rest});
		{more, _Length} ->
			wait_reply_header(State)
	end.

wait_reply_header(State=#state{client_socket=Socket,
                                           transport=Transport, timeout=T, client_buffer=Buffer}) ->
	{ok, Data} = Transport:recv(Socket, 0, T),
	start_parse_reply_header(State#state{client_buffer= << Buffer/binary, Data/binary >>}).
	
parse_reply_header({http_header, _I, 'Connection', _R, Connection}, State=#state{http_rep=Rep}) ->
	ConnAtom = agilitycache_http_protocol_parser:response_connection_parse(Connection),
	start_parse_reply_header(
	    State#state{
	        http_rep=Rep#http_rep{connection=ConnAtom,
	                              headers=[{'Connection', Connection}|Rep#http_rep.headers]
	                             }});
parse_reply_header({http_header, _I, Field, _R, Value}, State=#state{http_rep=Rep}) ->
	Field2 = agilitycache_http_protocol_parser:format_header(Field),
	start_parse_reply_header(
	    State#state{http_rep=Rep#http_rep{headers=[{Field2, Value}|Rep#http_rep.headers]}});
%% Cache Miss Request
parse_reply_header(http_eoh, State = #state{cache_status = miss}) ->
	check_cacheability(State);
%% Normal request
parse_reply_header(http_eoh, State) ->
	%%  OK, esperar pedido do cliente.
	{reply, ok, State};
parse_reply_header({http_error, <<"\r\n">>}, State=#state{rep_empty_lines=N, max_empty_lines=N}) ->
	{error, {http_error, 400}, State};
parse_reply_header({http_error, <<"\r\n">>}, State=#state{rep_empty_lines=N}) ->
	start_parse_reply(State#state{rep_empty_lines=N + 1});
parse_reply_header({http_error, <<"\n">>}, State=#state{rep_empty_lines=N, max_empty_lines=N}) ->
	{error, {http_error, 400}, State};
parse_reply_header({http_error, <<"\n">>}, State=#state{rep_empty_lines=N}) ->
	start_parse_reply(State#state{rep_empty_lines=N + 1}).

close_socket(#state{client_socket=undefined}) ->
	ok;
close_socket(#state{transport=Transport, client_socket=Socket}) ->
	Transport:close(Socket).		



%%% ============================
%%% Plugin logic
%%% @todo: remover isto daqui? colocar em outro módulo?
%%% ============================

%% Vou limpar o cache_http_req, pois só uso aqui
check_cacheability(State = #state{http_rep=HttpRep, cache_plugin = Plugin, cache_http_req = HttpReq, cache_id = FileId}) ->
	Cacheable = Plugin:cacheable(HttpReq, HttpRep),
	lager:debug("Plugin: ~p~n", [Plugin]),
	lager:debug("HttpReq: ~p~n", [HttpReq]),
	lager:debug("HttpRep: ~p~n", [HttpRep]),
	lager:debug("Cacheable: ~p~n", [Cacheable]),
	case Cacheable of
		true ->
			lager:debug("Cache Miss cacheable"),
			MaxAge = Plugin:expires(HttpReq, HttpRep),
			lager:debug("MaxAge: ~p", [MaxAge]),
			%% I'll set age after... put age = MaxAge here to simplify
			CachedFileInfo = #cached_file_info{ http_rep = HttpRep, max_age = MaxAge, age = MaxAge },
			agilitycache_database:write_info(FileId, CachedFileInfo),
			{ok, Helper} = agilitycache_http_client_miss_helper:start_link(),
			agilitycache_http_client_miss_helper:open(FileId, Helper),
			{reply, ok, State#state{cache_http_req = undefined, cache_info = CachedFileInfo, cache_file_helper = Helper}};
		false ->
			lager:debug("Miss no_cache after cacheability"),
			{reply, ok, State#state{cache_status = undefined, cache_http_req = undefined}}
	end.

check_pre_cacheability(HttpReq, State = #state{cache_plugin = Plugin}, Fun) ->
	Cacheable = Plugin:cacheable(HttpReq),
	lager:debug("Plugin: ~p~n", [Plugin]),
	lager:debug("HttpReq: ~p~n", [HttpReq]),
	lager:debug("Cacheable: ~p~n", [Cacheable]),
	case Cacheable of
		true ->
			%% Hit? checar database
			check_hit(HttpReq, State, Fun);
		false ->
			lager:debug("Miss no_cache"),
			Fun(HttpReq, State)
	end.


check_hit(HttpReq, State = #state{cache_plugin = Plugin}, Fun) ->
	FileId = Plugin:file_id(HttpReq),
	lager:debug("FileId: ~p <-> ~p~n", [agilitycache_utils:hexstring(FileId), FileId]),

	case agilitycache_cache_dir:find_file(FileId) of
		{error, _} ->
			lager:debug("Cache Miss"),
			Fun1 = fun() -> case mnesia:wread({agilitycache_transit_file, FileId}) of
				                [] ->
					                mnesia:write(#agilitycache_transit_file{ id = FileId, status = downloading}),
					                ok;
				                [_Record] ->
					                error
			                end
			       end,
			case mnesia:transaction(Fun1) of
				{atomic, ok} ->
					Fun(HttpReq, State#state{cache_status = miss, cache_http_req = HttpReq, cache_id = FileId});
				{atomic, error} ->
					lager:debug("Denied by mnesia"),
					Fun(HttpReq, State#state{cache_status = undefined})
			end;
		{ok, Path} ->
			check_hit2(HttpReq, State, FileId, Path, Fun)
	end.

check_hit2(HttpReq, State, FileId, Path, Fun) ->
	case agilitycache_database:read_preliminar_info(FileId, #cached_file_info{}) of
		{ok, CachedFileInfo0 = #cached_file_info{max_age = MaxAge0}} ->
			MaxAge = calendar:datetime_to_gregorian_seconds(MaxAge0),
			Now = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
			handle_expired(Now > MaxAge, HttpReq, State, FileId, Path, MaxAge, CachedFileInfo0, Fun);
		{error, _} = Z ->
			lager:debug("Database error: ~p", [Z]),
			Fun(HttpReq, State#state{cache_status = undefined})
	end.
handle_expired(false, HttpReq, State, FileId, Path, MaxAge, CachedFileInfo, Fun) ->
	lager:debug("Cache Hit: ~p", [Path]),
	lager:debug("MaxAge: ~p", [MaxAge]),
	Fun2 = fun() -> case mnesia:wread({agilitycache_transit_file, FileId}) of
		                [] ->
			                mnesia:write(#agilitycache_transit_file{
			                                id = FileId,
			                                status = reading,
			                                concurrent_readers = 1}),
			                lager:debug("Mnesia empty"),
			                ok;
		                [Record = #agilitycache_transit_file{ status = reading,
		                                                      concurrent_readers = CR}] when CR >= 1 ->
			                lager:debug("Mnesia concurrent"),
			                mnesia:write(Record#agilitycache_transit_file{concurrent_readers = CR + 1}),
			                lager:debug("Mnesia concurrent_readers: ~p", [CR + 1]),
			                ok;
		                Er32 ->
			                lager:debug("Mnesia error: ~p", [Er32]),
			                error
	                end
	       end,
	case mnesia:transaction(Fun2) of
		{atomic, ok} ->
			{reply, HttpReq,
			 State#state{cache_status = hit,
			                         cache_info = CachedFileInfo, cache_id = FileId, cache_file_path = Path}};
		{atomic, error} ->
			lager:debug("Denied by mnesia"),
			Fun(HttpReq, State#state{cache_status = undefined})
	end;
handle_expired(true, HttpReq, State, FileId, _Path, MaxAge, _CachedFileInfo, Fun) ->
	%% Expired
	%% Não manusear por enquanto
	lager:debug("Expired!, MaxAge: ~p", [MaxAge]),
	Fun3 = fun() -> case mnesia:wread({agilitycache_transit_file, FileId}) of
		                [] ->
			                mnesia:write(#agilitycache_transit_file{ id = FileId, status = downloading}),
			                ok;
		                [_Record] ->
			                error
	                end
	       end,
	case mnesia:transaction(Fun3) of
		{atomic, ok} ->
			Fun(HttpReq, State#state{cache_status = miss, cache_http_req = HttpReq, cache_id = FileId});
		{atomic, error} ->
			lager:debug("Denied by mnesia"),
			Fun(HttpReq, State#state{cache_status = undefined})
	end.


check_plugins(HttpReq, State, Fun) ->
	Plugins = agilitycache_utils:get_app_env(plugins, [{cache, []}]),
	CachePlugins = proplists:get_value(cache, Plugins, []) ++ [agilitycache_cache_plugin_default],
	lager:debug("CachePlugins: ~p~n", [CachePlugins]),
	lager:debug("HttpReq: ~p~n", [HttpReq]),
	InCharge = test_in_charge_plugins(CachePlugins, HttpReq, agilitycache_cache_plugin_default),
	lager:debug("InCharge: ~p~n", [InCharge]),
	check_pre_cacheability(HttpReq, State#state{cache_plugin = InCharge}, Fun).

test_in_charge_plugins([], _, Default) ->
	Default;
test_in_charge_plugins([Plugin | T], HttpReq, Default) ->
	case Plugin:in_charge(HttpReq) of
		true ->	Plugin;
		false -> test_in_charge_plugins(T, HttpReq, Default)
	end.
