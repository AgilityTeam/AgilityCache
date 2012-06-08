%% Author: osmano807
%% Created: Dec 27, 2011
%% Description: TODO: Add description to agilitycache_http_client
-module(agilitycache_http_client).

%%
%% Include files
%%
-include("cache.hrl"). %% superseeds http.hrl

%%
%% Exported Functions
%%
-export([new/3, start_request/2, start_keepalive_request/2, start_receive_reply/1, get_http_rep/1, set_http_rep/2, get_body/1, send_data/2, stop/2]).

-record(http_client_state, {
            http_rep :: #http_rep{},
            client_socket :: inet:socket(),
            transport :: module(),
            rep_empty_lines = 0 :: integer(),
            max_empty_lines :: integer(),
            timeout = 5000 :: timeout(),
            client_buffer = <<>> :: binary(),
            cache_plugin = agilitycache_cache_plugin_default :: module(),
            cache_status = undefined :: undefined | miss | hit,
            cache_id = <<>> :: binary(),
            cache_info = #cached_file_info{} :: #cached_file_info{},
            cache_file_path = <<>> :: binary(),
            cache_file_helper = undefined :: pid(),
            cache_file_handle :: file:io_device(),
            cache_http_req :: #http_req{} %% Only set and used when cache_status = miss
           }).

-opaque http_client_state() :: #http_client_state{}.
-export_type([http_client_state/0]).

%%
%% API Functions
%%

-spec new(Transport :: module(), Timeout :: non_neg_integer(), MaxEmptyLines :: non_neg_integer()) -> http_client_state().
new(Transport, Timeout, MaxEmptyLines) ->
	#http_client_state{timeout=Timeout, max_empty_lines=MaxEmptyLines, transport=Transport}.

-spec get_http_rep(http_client_state()) -> {#http_rep{}, http_client_state()}.
get_http_rep(#http_client_state{http_rep = HttpRep} = State) ->
	{HttpRep, State}.

-spec set_http_rep(#http_rep{}, http_client_state()) -> http_client_state().
set_http_rep(HttpRep, State) ->
	State#http_client_state{http_rep = HttpRep}.

-spec start_request(#http_req{}, http_client_state()) -> {ok, #http_req{}, http_client_state()} | {error, any(), http_client_state()}.
start_request(HttpReq, State) ->
	check_plugins(HttpReq, State, fun start_connect/2).

-spec start_connect(#http_req{}, http_client_state()) -> {ok, #http_req{}, http_client_state()} | {error, any(), http_client_state()}.
start_connect(HttpReq =
	              #http_req{ uri=_Uri=#http_uri{ domain = Host, port = Port}}, State=#http_client_state{transport = Transport, timeout = Timeout}) ->

	BufferSize = agilitycache_utils:get_app_env(agilitycache, buffer_size, 87380),
	TransOpts = [
	             %%{nodelay, true}%, %% We want to be informed even when packages are small
	             {send_timeout, Timeout}, %% If we couldn't send a message in Timeout time something is definitively wrong...
	             {send_timeout_close, true}, %%... and therefore the connection should be closed
	             {buffer, BufferSize},
	             {delay_send, true}
	            ],
	lager:debug("Host: ~p Port: ~p", [Host, Port]),
	case Transport:connect(binary_to_list(Host), Port, TransOpts, Timeout) of
		{ok, Socket} ->
			start_send_request(HttpReq, State#http_client_state{client_socket = Socket});
		{error, Reason} ->
			{error, Reason, State}
	end.

-spec start_keepalive_request(HttpReq :: #http_req{}, State :: http_client_state()) -> {ok, #http_req{}, http_client_state()} | {error, any(), http_client_state()}.
start_keepalive_request(_HttpReq, State = #http_client_state{client_socket = undefined}) ->
	{error, invalid_socket, State};
start_keepalive_request(HttpReq, State) ->
	check_plugins(HttpReq, State, fun start_send_request/2).

-spec start_receive_reply(http_client_state()) -> {ok, http_client_state()} | {error, any(), http_client_state()}.
start_receive_reply(State = #http_client_state{cache_status = hit, cache_info = CachedFileInfo,
                                               cache_id = FileId, cache_file_path=Path, cache_plugin = Plugin}) ->
	lager:debug("Cache Hit"),
	{ok, CachedFileInfo0} = agilitycache_database:read_remaining_info(FileId, CachedFileInfo),
	{ok, FileHandle} = file:open(Path, [raw, read, binary]),
	HttpRep = CachedFileInfo0#cached_file_info.http_rep,
	lager:debug("HttpRep: ~p", [HttpRep]),
	{ok, State#http_client_state{cache_info = CachedFileInfo0, http_rep=HttpRep#http_rep{
		  headers = [{<<"X-Agilitycache">>, agilitycache_utils:hexstring(FileId)},
		             {<<"X-Cache">>, <<"Hit">>},
		             {<<"X-Plugin">>, Plugin:name()} |
		             HttpRep#http_rep.headers]}, cache_file_handle=FileHandle}};
start_receive_reply(State) ->
	start_parse_reply(State).

-spec get_body(http_client_state()) -> {ok, iolist(), http_client_state()} | {error, any(), http_client_state()}.

%% Cache Hit functions
get_body(State=#http_client_state{cache_status = hit, cache_file_handle=FileHandle}) ->
	case file:read(FileHandle, 8192) of
		{ok, Data} ->
			{ok, Data, State};
		eof ->
			{ok, <<>>, State};
		{error, Reason} ->
			{error, Reason, State}
	end;

%% Cache Miss functions

%% Empty buffer
get_body(State=#http_client_state{
             client_socket=Socket, transport=Transport, timeout=T, client_buffer= <<>>, cache_status=miss, cache_file_helper=FileHelper})->
	case Transport:recv(Socket, 0, T) of
		{ok, Data} ->
			agilitycache_http_client_miss_helper:write(Data, FileHelper),
			{ok, Data, State};
		{error, timeout} ->
			{error, timeout, State};
		{error, closed} ->
			{error, closed, State};
		Other ->
			{error, Other, State}
	end;
%% Non empty buffer
get_body(State=#http_client_state{client_buffer=Buffer, cache_status=miss, cache_file_helper=FileHelper})->
	agilitycache_http_client_miss_helper:write(Buffer, FileHelper),
	{ok, Buffer, State#http_client_state{client_buffer = <<>>}};

%% No cache functions

%% Empty buffer
get_body(State=#http_client_state{
             client_socket=Socket, transport=Transport, timeout=T, client_buffer= <<>>})->
	case Transport:recv(Socket, 0, T) of
		{ok, Data} ->

			{ok, Data, State};
		{error, timeout} ->
			{error, timeout, State};
		{error, closed} ->
			{error, closed, State};
		Other ->
			{error, Other, State}
	end;
%% Non empty buffer
get_body(State=#http_client_state{client_buffer=Buffer})->
	{ok, Buffer, State#http_client_state{client_buffer = <<>>}}.

-spec send_data(iolist(), http_client_state()) -> {ok, http_client_state()} | {error, any(), http_client_state()}.
send_data(Data, State = #http_client_state { transport = Transport, client_socket = Socket } ) ->
	case Transport:send(Socket, Data) of
		ok ->
			{ok, State};
		{error, Reason} ->
			{error, Reason, State}
	end.

-spec stop(keepalive | close, http_client_state()) -> {ok, http_client_state()}.
stop(Type, State=#http_client_state{cache_status=hit, cache_file_handle=FileHandle, cache_info=CachedFileInfo, cache_id=FileId}) ->
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
	case Type of
		keepalive ->
			{ok, State#http_client_state{cache_status=undefined, cache_file_handle=undefined}};
		close ->
			close(State)
	end;
stop(Type, State=#http_client_state{cache_status=miss, cache_file_helper=FileHelper, cache_id=FileId}) ->
	%% Removendo índice do db
	mnesia:transaction(fun() -> mnesia:delete({agilitycache_transit_file, FileId}) end),
	agilitycache_http_client_miss_helper:close(FileHelper),
	case Type of
		keepalive ->
			{ok, State#http_client_state{cache_status=undefined, cache_file_helper=undefined}};
		close ->
			close(State)
	end;
stop(keepalive, State) ->
	{ok, State};
stop(close, State) ->
	close(State).

%%
%% Local Functions
%%

-spec close(http_client_state()) -> {ok, http_client_state()}.
close(State = #http_client_state{transport=Transport, client_socket=Socket}) ->
	case Socket of
		undefined ->
			{ok, State};
		_ ->
			Transport:close(Socket),
			{ok, State#http_client_state{client_socket=undefined}}
	end.

start_send_request(HttpReq, State = #http_client_state{client_socket=Socket, transport=Transport}) ->
	%%lager:debug("ClientSocket buffer ~p,~p,~p",
	%%        [inet:getopts(Socket, [buffer]), inet:getopts(Socket, [recbuf]), inet:getopts(Socket, [sndbuf]) ]),
	Packet = agilitycache_http_req:request_head(HttpReq),
	lager:debug("Packet: ~p~n", [Packet]),
	lager:debug("HttpReq: ~p~n", [HttpReq]),
	case Transport:send(Socket, Packet) of
		ok ->
			{ok, HttpReq, State};
		{error, Reason} ->
			{error, Reason, State}
	end.

start_parse_reply(State=#http_client_state{client_buffer=Buffer}) ->
	case erlang:decode_packet(http_bin, Buffer, []) of
		{ok, Reply, Rest} ->
			parse_reply({Reply, State#http_client_state{client_buffer=Rest}});
		{more, _Length} ->
			wait_reply(State);
		{error, Reason} ->
			{error, Reason, State}
	end.

wait_reply(State = #http_client_state{client_socket=Socket, transport=Transport, timeout=T, client_buffer=Buffer}) ->
	case Transport:recv(Socket, 0, T) of
		{ok, Data} ->
			start_parse_reply(State#http_client_state{client_buffer= << Buffer/binary, Data/binary >>});
		{error, Reason} ->
			{error, Reason, State}
	end.

parse_reply({{http_response, Version, Status, String}, State}) ->
	ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
	start_parse_reply_header(
	    State#http_client_state{http_rep=#http_rep{connection=ConnAtom, status=Status, version=Version, string=String}}
	   );
parse_reply({{http_error, <<"\r\n">>}, State=#http_client_state{rep_empty_lines=_N, max_empty_lines=_N}}) ->
	{error, {http_error, 400}, State};
parse_reply({_Data={http_error, <<"\r\n">>}, State=#http_client_state{rep_empty_lines=N}}) ->
	start_parse_reply(State#http_client_state{rep_empty_lines=N + 1});
parse_reply({{http_error, _Any}, State}) ->
	{error, {http_error, 400}, State}.

start_parse_reply_header(State=#http_client_state{client_buffer=Buffer}) ->
	case erlang:decode_packet(httph_bin, Buffer, []) of
		{ok, Header, Rest} ->
			parse_reply_header(Header, State#http_client_state{client_buffer=Rest});
		{more, _Length} ->
			wait_reply_header(State);
		{error, _Reason} ->
			{error, {http_error, 400}, State}
	end.

wait_reply_header(State=#http_client_state{client_socket=Socket,
                                           transport=Transport, timeout=T, client_buffer=Buffer}) ->
	case Transport:recv(Socket, 0, T) of
		{ok, Data} ->
			start_parse_reply_header(State#http_client_state{client_buffer= << Buffer/binary, Data/binary >>});
		{error, Reason} ->
			{error, {error, Reason}, State}
	end.

parse_reply_header({http_header, _I, 'Connection', _R, Connection}, State=#http_client_state{http_rep=Rep}) ->
	ConnAtom = agilitycache_http_protocol_parser:response_connection_parse(Connection),
	start_parse_reply_header(
	    State#http_client_state{
	        http_rep=Rep#http_rep{connection=ConnAtom,
	                              headers=[{'Connection', Connection}|Rep#http_rep.headers]
	                             }});
parse_reply_header({http_header, _I, Field, _R, Value}, State=#http_client_state{http_rep=Rep}) ->
	Field2 = agilitycache_http_protocol_parser:format_header(Field),
	start_parse_reply_header(
	    State#http_client_state{http_rep=Rep#http_rep{headers=[{Field2, Value}|Rep#http_rep.headers]}});
%% Cache Miss Request
parse_reply_header(http_eoh, State = #http_client_state{cache_status = miss}) ->
	check_cacheability(State);
%% Normal request
parse_reply_header(http_eoh, State) ->
	%%  OK, esperar pedido do cliente.
	{ok, State};
parse_reply_header({http_error, <<"\r\n">>}, State=#http_client_state{rep_empty_lines=N, max_empty_lines=N}) ->
	{error, {http_error, 400}, State};
parse_reply_header({http_error, <<"\r\n">>}, State=#http_client_state{rep_empty_lines=N}) ->
	start_parse_reply(State#http_client_state{rep_empty_lines=N + 1});
parse_reply_header({http_error, <<"\n">>}, State=#http_client_state{rep_empty_lines=N, max_empty_lines=N}) ->
	{error, {http_error, 400}, State};
parse_reply_header({http_error, <<"\n">>}, State=#http_client_state{rep_empty_lines=N}) ->
	start_parse_reply(State#http_client_state{rep_empty_lines=N + 1});
parse_reply_header({http_error, _Bin}, State) ->
	{error, {http_error, 500}, State}.

%%% ============================
%%% Plugin logic
%%% @todo: remover isto daqui? colocar em outro módulo?
%%% ============================

%% Vou limpar o cache_http_req, pois só uso aqui
check_cacheability(State = #http_client_state{http_rep=HttpRep, cache_plugin = Plugin, cache_http_req = HttpReq, cache_id = FileId}) ->
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
			{ok, Helper} = agilitycache_http_client_miss_helper:start(),
			agilitycache_http_client_miss_helper:open(FileId, Helper),
			{ok, State#http_client_state{cache_http_req = undefined, cache_info = CachedFileInfo, cache_file_helper = Helper}};
		false ->
			lager:debug("Miss no_cache after cacheability"),
			{ok, State#http_client_state{cache_status = undefined, cache_http_req = undefined}}
	end.

check_pre_cacheability(HttpReq, State = #http_client_state{cache_plugin = Plugin}, Fun) ->
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


check_hit(HttpReq, State = #http_client_state{cache_plugin = Plugin}, Fun) ->
	FileId = Plugin:file_id(HttpReq),
	lager:debug("FileId: ~p <-> ~p~n", [agilitycache_utils:hexstring(FileId), FileId]),
	case agilitycache_cache_dir:find_file(FileId) of
		{error, _} ->
			lager:debug("Cache Miss"),
			Fun1 = fun() ->
					       case mnesia:wread({agilitycache_transit_file, FileId}) of
						       [] ->
							       mnesia:write(#agilitycache_transit_file{ id = FileId, status = downloading}),
							       ok;
						       [_Record] ->
							       error
					       end
			       end,
			case mnesia:transaction(Fun1) of
				{atomic, ok} ->
					Fun(HttpReq, State#http_client_state{cache_status = miss, cache_http_req = HttpReq, cache_id = FileId});
				{atomic, error} ->
					lager:debug("Denied by mnesia"),
					Fun(HttpReq, State#http_client_state{cache_status = undefined})
			end;
		{ok, Path} ->
			case agilitycache_database:read_preliminar_info(FileId, #cached_file_info{}) of
				{ok, CachedFileInfo0 = #cached_file_info{max_age = MaxAge0}} ->
					MaxAge = calendar:datetime_to_gregorian_seconds(MaxAge0),
					Now = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
					case Now < MaxAge of
						true ->
							lager:debug("Cache Hit: ~p", [Path]),
							lager:debug("MaxAge: ~p", [MaxAge]),
							Fun2 = fun() ->
									       case mnesia:wread({agilitycache_transit_file, FileId}) of
										       [] ->
											       mnesia:write(#agilitycache_transit_file{ id = FileId, status = reading, concurrent_readers = 1}),
											       lager:debug("Mnesia empty"),
											       ok;
										       [Record = #agilitycache_transit_file{ status = reading, concurrent_readers = CR}] when CR >= 1 ->
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
									{ok, HttpReq,
									 State#http_client_state{cache_status = hit, cache_info = CachedFileInfo0, cache_id = FileId, cache_file_path = Path}};
								{atomic, error} ->
									lager:debug("Denied by mnesia"),
									Fun(HttpReq, State#http_client_state{cache_status = undefined})
							end;
						false ->
							%% Expired
							%% Não manusear por enquanto
							lager:debug("Expired!, MaxAge: ~p", [MaxAge]),
							Fun3 = fun() ->
									       case mnesia:wread({agilitycache_transit_file, FileId}) of
										       [] ->
											       mnesia:write(#agilitycache_transit_file{ id = FileId, status = downloading}),
											       ok;
										       [_Record] ->
											       error
									       end
							       end,
							case mnesia:transaction(Fun3) of
								{atomic, ok} ->
									Fun(HttpReq, State#http_client_state{cache_status = miss, cache_http_req = HttpReq, cache_id = FileId});
								{atomic, error} ->
									lager:debug("Denied by mnesia"),
									Fun(HttpReq, State#http_client_state{cache_status = undefined})
							end
					end;
				{error, _} = Z ->
					lager:debug("Database error: ~p", [Z]),
					Fun(HttpReq, State#http_client_state{cache_status = undefined})
			end
	end.

check_plugins(HttpReq, State, Fun) ->
	Plugins = agilitycache_utils:get_app_env(plugins, [{cache, []}]),
	CachePlugins = lists:append([proplists:get_value(cache, Plugins, []), [agilitycache_cache_plugin_default]]),
	lager:debug("CachePlugins: ~p~n", [CachePlugins]),
	lager:debug("HttpReq: ~p~n", [HttpReq]),
	InCharge = test_in_charge_plugins(CachePlugins, HttpReq, agilitycache_cache_plugin_default),
	lager:debug("InCharge: ~p~n", [InCharge]),
	check_pre_cacheability(HttpReq, State#http_client_state{cache_plugin = InCharge}, Fun).

test_in_charge_plugins([], _, Default) ->
	Default;
test_in_charge_plugins([Plugin | T], HttpReq, Default) ->
	case Plugin:in_charge(HttpReq) of
		true ->
			Plugin;
		false ->
			test_in_charge_plugins(T, HttpReq, Default)
	end.

