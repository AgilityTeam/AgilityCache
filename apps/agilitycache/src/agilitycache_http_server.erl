%% Author: osmano807
%% Created: Dec 27, 2011
%% Description: TODO: Add description to agilitycache_http_server
-module(agilitycache_http_server).

%%
%% Include files
%%
-include("include/http.hrl").

%%
%% Exported Functions
%%
-export([new/4, read_request/1, read_keepalive_request/2, get_body/1, send_data/2, get_http_req/1, set_http_req/2, close/1]).

-record(http_server_state, {
	  http_req :: #http_req{},
	  server_socket :: inet:socket(),	  
	  transport :: module(),
	  req_empty_lines = 0 :: integer(),	  
	  max_empty_lines :: integer(),
	  timeout = 5000 :: timeout(),
	  server_buffer = <<>> :: binary()	
}).

-opaque http_server_state() :: #http_server_state{}.
-export_type([http_server_state/0]).

%%
%% API Functions
%%

-spec new(Transport :: module(), ServerSocket :: inet:socket(), Timeout :: non_neg_integer(), MaxEmptyLines :: non_neg_integer()) -> http_server_state().
new(Transport, ServerSocket, Timeout, MaxEmptyLines) ->
	#http_server_state{timeout=Timeout, max_empty_lines=MaxEmptyLines, transport=Transport, server_socket=ServerSocket}.

-spec get_http_req(http_server_state()) -> {#http_req{}, http_server_state()}.
get_http_req(#http_server_state{http_req = HttpReq} = State) ->
  {HttpReq, State}.

-spec set_http_req(#http_req{}, http_server_state()) -> http_server_state().
set_http_req(HttpReq, State) ->
    State#http_server_state{http_req = HttpReq}.

%% @todo improve this spec
-spec read_request(http_server_state()) -> {ok, http_server_state()} | {error, any(), http_server_state()}.
read_request(State) ->
    wait_request(State).

-spec read_keepalive_request(non_neg_integer(), http_server_state()) -> {ok, http_server_state()} | {error, any(), http_server_state()}.
read_keepalive_request(KeepAliveTimeout, State) ->
      wait_keepalive_request(KeepAliveTimeout, State).

-spec get_body(http_server_state()) -> {ok, iolist(), http_server_state()} | {error, any(), http_server_state()}.
%% Empty buffer
get_body(State=#http_server_state{
		  server_socket=Socket, transport=Transport, timeout=T, server_buffer= <<>>})->
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
get_body(State=#http_server_state{server_buffer=Buffer})->
    {ok, Buffer, State#http_server_state{server_buffer = <<>>}}.

-spec send_data(iolist(), http_server_state()) -> {ok, http_server_state()} | {error, any(), http_server_state()}.
send_data(Data, State = #http_server_state { transport = Transport, server_socket = Socket } ) ->
  case Transport:send(Socket, Data) of
    ok ->
      {ok, State};
    {error, Reason} ->
      {error, Reason, State}
  end.

-spec close(http_server_state()) -> {ok, http_server_state()}.
close(State = #http_server_state{transport=Transport, server_socket=Socket}) ->
  case Socket of
    undefined ->
      {ok, State};
    _ ->
      Transport:close(Socket),
      {ok, State#http_server_state{server_socket=Socket}}
  end.


%%
%% Local Functions
%%

wait_request(State=#http_server_state{server_socket=Socket, transport=Transport,
    timeout=T, server_buffer=Buffer}) ->
  case Transport:recv(Socket, 0, T) of
    {ok, Data} ->
      start_parse_request(State#http_server_state{server_buffer = << Buffer/binary, Data/binary>>});
    {error, timeout} ->
      {error, {http_error, 408}, State};
    {error, closed} ->
      {error, closed, State}
  end.

wait_keepalive_request(KeepAliveTimeout, State=#http_server_state{server_socket=Socket, transport=Transport, server_buffer=Buffer}) ->
  case Transport:recv(Socket, 0, KeepAliveTimeout) of
    {ok, Data} ->
      start_parse_request(State#http_server_state{server_buffer = << Buffer/binary, Data/binary>>});
    {error, timeout} ->
      {error, {http_error, 408}, State};
    {error, closed} ->
      {error, closed, State}
  end.


%% @todo Use decode_packet options to limit length?
start_parse_request(State=#http_server_state{server_buffer=Buffer}) ->
  %error_logger:info_msg("~p Nova requisição...~n", [self()]),
  case erlang:decode_packet(http_bin, Buffer, []) of
    {ok, Request, Rest} ->
      parse_request(Request, State#http_server_state{server_buffer=Rest});
    {more, _Length} ->
      wait_request(State);
    {error, _Reason} ->
      {error, {http_error, 400}, State}
  end.

parse_request({http_request, Method, {abs_path, AbsPath}, Version}, State) ->
  {Path, RawPath, Qs} = agilitycache_dispatcher:split_path(AbsPath),
  ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
  start_parse_request_header(State#http_server_state{http_req=#http_req{
        connection=ConnAtom, method=Method, version=Version,
        path=Path, raw_path=RawPath, raw_qs=Qs}});
parse_request({http_request, Method, {absoluteURI, http, RawHost, RawPort, AbsPath}, Version},
    State=#http_server_state{transport=Transport}) ->
    {Path, RawPath, Qs} = agilitycache_dispatcher:split_path(AbsPath),
    ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
    RawHost2 = cowboy_bstr:to_lower(RawHost),
    DefaultPort = agilitycache_http_protocol_parser:default_port(Transport:name()),
    HttpReq = #http_req{connection=ConnAtom, method=Method, version=Version,
      path=Path, raw_path=RawPath, raw_qs=Qs},
    State2 = case {RawPort, agilitycache_dispatcher:split_host(RawHost2)} of
      {DefaultPort, {Host, RawHost3, _}} ->
        State#http_server_state{http_req=HttpReq#http_req{
            host=Host, raw_host=RawHost3, port=DefaultPort,
            headers=[{'Host', RawHost3}]}};
      {_, {Host, RawHost3, DefaultPort}} ->
        State#http_server_state{http_req=HttpReq#http_req{
            host=Host, raw_host=RawHost3, port=DefaultPort,
            headers=[{'Host', RawHost3}]}};
      {undefined, {Host, RawHost3, undefined}} ->
        State#http_server_state{http_req=HttpReq#http_req{
            host=Host, raw_host=RawHost3, port=DefaultPort,
            headers=[{'Host', RawHost3}]}};
      {undefined, {Host, RawHost3, Port}} ->
        BinaryPort = list_to_binary(integer_to_list(Port)),
        State#http_server_state{http_req=HttpReq#http_req{
            host=Host, raw_host=RawHost3, port=Port,
            headers=[{'Host', << RawHost3/binary, ":", BinaryPort/binary>>}]}};
      {Port, {Host, RawHost3, _}} ->
        BinaryPort = list_to_binary(integer_to_list(Port)),
        State#http_server_state{http_req=HttpReq#http_req{
            host=Host, raw_host=RawHost3, port=Port,
            headers=[{'Host', << RawHost3/binary, ":", BinaryPort/binary >>}]}};
      _ ->
        {{http_error, 400}, State}
    end,
    case State2 of
      {stop, Reason, SubState} ->
        {error, Reason, SubState};
      _ ->
        start_parse_request_header(State2)
    end;
parse_request({http_request, _Method, _URI, _Version}, State) ->
  {error, {http_error, 501}, State};
parse_request({http_error, <<"\r\n">>},
    State=#http_server_state{req_empty_lines=N, max_empty_lines=N}) ->
    {error, {http_error, 400}, State};
parse_request({http_error, <<"\r\n">>}, State=#http_server_state{req_empty_lines=N}) ->
  start_parse_request(State#http_server_state{req_empty_lines=N + 1});
parse_request({http_error, <<"\n">>},
    State=#http_server_state{req_empty_lines=N, max_empty_lines=N}) ->
    {error, {http_error, 400}, State};
parse_request({http_error, <<"\n">>}, State=#http_server_state{req_empty_lines=N}) ->
    start_parse_request(State#http_server_state{req_empty_lines=N + 1});
parse_request({http_error, _Any}, State) ->
    {error, {http_error, 400}, State};
parse_request(_Shit, State) ->
    {error, {http_error, 500}, State}.

start_parse_request_header(State=#http_server_state{server_buffer=Buffer}) ->
    case erlang:decode_packet(httph_bin, Buffer, []) of
	{ok, Header, Rest} ->
	    parse_request_header(Header, State#http_server_state{server_buffer=Rest});
	{more, _Length} ->
	    wait_request_header(State);
	{error, _Reason} ->
	    {error, {http_error, 400}, State}
    end.

wait_request_header(State=#http_server_state{server_socket=Socket, transport=Transport, timeout=T, server_buffer=Buffer}) ->
    case Transport:recv(Socket, 0, T) of
	{ok, Data} ->
	    start_parse_request_header(State#http_server_state{server_buffer= << Buffer/binary, Data/binary >>});
	{error, timeout} ->
	    {error, {http_error, 408}, State};
	{error, closed} ->
	    {error, {http_error, 500}, State}
    end.

parse_request_header({http_header, _I, 'Host', _R, RawHost}, State = #http_server_state{transport=Transport, http_req=Req=#http_req{host=undefined}}) ->
  RawHost2 = cowboy_bstr:to_lower(RawHost),
  DefaultPort = agilitycache_http_protocol_parser:default_port(Transport:name()),
  State2 = case agilitycache_dispatcher:split_host(RawHost2) of
    {Host, RawHost3, DefaultPort} ->
      State#http_server_state{http_req=Req#http_req{
          host=Host, raw_host=RawHost3, port=DefaultPort,
          headers=[{'Host', RawHost3}|Req#http_req.headers]}};
    {Host, RawHost3, undefined} ->
      State#http_server_state{http_req=Req#http_req{
          host=Host, raw_host=RawHost3, port=DefaultPort,
          headers=[{'Host', RawHost3}|Req#http_req.headers]}};
    {Host, RawHost3, Port}->
      BinaryPort = list_to_binary(integer_to_list(Port)),
      State#http_server_state{http_req=Req#http_req{
          host=Host, raw_host=RawHost3, port=Port,
          headers=[{'Host', << RawHost3/binary, ":", BinaryPort/binary>>}|Req#http_req.headers]}};
    _ ->
      {error, {http_error, 400}, State}
  end,
  case State2 of
    {stop, Reason, SubState} ->
      {error, Reason, SubState};
    _ ->
      start_parse_request_header(State2)
  end;
%% Ignore Host headers if we already have it.
parse_request_header({http_header, _I, 'Host', _R, _V}, State) ->
    start_parse_request_header(State);
parse_request_header({http_header, _I, 'Connection', _R, Connection}, State = #http_server_state{http_req=Req}) ->
    ConnAtom = agilitycache_http_protocol_parser:response_connection_parse(Connection),
    start_parse_request_header(State#http_server_state{http_req=Req#http_req{connection=ConnAtom,
								 headers=[{'Connection', Connection}|Req#http_req.headers]}});
parse_request_header({http_header, _I, Field, _R, Value}, State = #http_server_state{http_req=Req}) ->
    Field2 = agilitycache_http_protocol_parser:format_header(Field),
    start_parse_request_header(State#http_server_state{http_req=Req#http_req{headers=[{Field2, Value}|Req#http_req.headers]}});
%% The Host header is required in HTTP/1.1.
parse_request_header(http_eoh, State=#http_server_state{http_req=Req}) when Req#http_req.version=:= {1, 1} andalso Req#http_req.host=:=undefined ->
    {error, {http_error, 400}, State};
%% It is however optional in HTTP/1.0.
%% @todo Devia ser um erro, host undefined o.O
parse_request_header(http_eoh, State=#http_server_state{transport=Transport, http_req=Req=#http_req{version={1, 0}, host=undefined}}) ->
    Port = agilitycache_http_protocol_parser:default_port(Transport:name()),
    %% Ok, terminar aqui, e esperar envio!
    {ok, State#http_server_state{http_req=Req#http_req{host=[], raw_host= <<>>, port=Port}}};
parse_request_header(http_eoh, State) ->
    %% Ok, terminar aqui, e esperar envio!
    {ok, State};
parse_request_header({http_error, _Bin}, State) ->
    {error, {http_error, 500}, State}.

