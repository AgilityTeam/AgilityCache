%% Author: osmano807
%% Created: Dec 27, 2011
%% Description: TODO: Add description to agilitycache_http_client
-module(agilitycache_http_client).

%%
%% Include files
%%
-include("include/http.hrl").

%%
%% Exported Functions
%%
-export([new/3, start_request/2, start_keepalive_request/2, start_receive_reply/1, get_http_rep/1, set_http_rep/2, get_body/1, send_data/2, close/1]).

-record(http_client_state, {
	  http_rep :: #http_rep{},
	  client_socket :: inet:socket(),	  
	  transport :: module(),
	  rep_empty_lines = 0 :: integer(),	  
	  max_empty_lines :: integer(),
	  timeout = 5000 :: timeout(),
	  client_buffer = <<>> :: binary()	
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

-spec start_request(HttpReq :: #http_req{}, State :: http_client_state()) -> {ok, #http_req{}, http_client_state()} | {error, any(), http_client_state()}.
start_request(HttpReq, State=#http_client_state{transport = Transport, timeout = Timeout}) ->
  {RawHost, HttpReq0} = agilitycache_http_req:raw_host(Transport, undefined, HttpReq), %% undefined no lugar do socket é seguro neste caso!
  {Port, HttpReq1} = agilitycache_http_req:port(Transport, undefined, HttpReq0),
  BufferSize = agilitycache_utils:get_app_env(agilitycache, buffer_size, 87380),
  TransOpts = [
    %{nodelay, true}%, %% We want to be informed even when packages are small
    {send_timeout, Timeout}, %% If we couldn't send a message in Timeout time something is definitively wrong...
    {send_timeout_close, true}, %%... and therefore the connection should be closed
    {buffer, BufferSize}
    ],
    case Transport:connect(binary_to_list(RawHost), Port, TransOpts, Timeout) of
      {ok, Socket} ->
        start_send_request(HttpReq1, State#http_client_state{client_socket = Socket});
      {error, Reason} ->
        {error, Reason, State}
    end.

-spec start_keepalive_request(HttpReq :: #http_req{}, State :: http_client_state()) -> {ok, #http_req{}, http_client_state()} | {error, any(), http_client_state()}.
start_keepalive_request(_HttpReq, State = #http_client_state{client_socket = undefined}) ->
    {error, invalid_socket, State};
start_keepalive_request(HttpReq, State) ->
  start_send_request(HttpReq, State).

-spec start_receive_reply(http_client_state()) -> {ok, http_client_state()} | {error, any(), http_client_state()}.
start_receive_reply(State) ->
  start_parse_reply(State).

-spec get_body(http_client_state()) -> {ok, iolist(), http_client_state()} | {error, any(), http_client_state()}.
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

-spec close(http_client_state()) -> {ok, http_client_state()}.
close(State = #http_client_state{transport=Transport, client_socket=Socket}) ->
  case Socket of
    undefined ->
      {ok, State};
    _ ->
      Transport:close(Socket),
      {ok, State#http_client_state{client_socket=Socket}}
  end.

%%
%% Local Functions
%%

start_send_request(HttpReq, State = #http_client_state{client_socket=Socket, transport=Transport}) ->
  %%error_logger:info_msg("ClientSocket buffer ~p,~p,~p", 
  %%        [inet:getopts(Socket, [buffer]), inet:getopts(Socket, [recbuf]), inet:getopts(Socket, [sndbuf]) ]),
  Packet = agilitycache_http_req:request_head(HttpReq),
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


