%% @doc HTTP protocol handler.
%%
%% The available options are:
%% <dl>
%%  <dt>dispatch</dt><dd>The dispatch list for this protocol.</dd>
%%  <dt>max_empty_lines</dt><dd>Max number of empty lines before a request.
%%   Defaults to 5.</dd>
%%  <dt>timeout</dt><dd>Time in milliseconds before an idle keep-alive
%%   connection is closed. Defaults to 5000 milliseconds.</dd>
%% </dl>
%%
%% Note that there is no need to monitor these processes when using Cowboy as
%% an application as it already supervises them under the listener supervisor.
%%
%% @see agilitycache_dispatcher
%% @see agilitycache_http_handler
-module(agilitycache_http_protocol).

-export([start_link/4]). %% API.
-export([init/4, parse_request/1]). %% FSM.

-include("include/http.hrl").
-include_lib("eunit/include/eunit.hrl").

-record(state, {
	listener :: pid(),
	socket :: inet:socket(),
	transport :: module(),
	dispatch :: agilitycache_dispatcher:dispatch_rules(),
	handler :: {module(), any()},
	req_empty_lines = 0 :: integer(),
	max_empty_lines :: integer(),
	timeout :: timeout(),
	connection = keepalive :: keepalive | close,
	buffer = <<>> :: binary()
}).

%% API.

%% @doc Start an HTTP protocol process.
-spec start_link(pid(), inet:socket(), module(), any()) -> {ok, pid()}.
start_link(ListenerPid, Socket, Transport, Opts) ->
	Pid = spawn_link(?MODULE, init, [ListenerPid, Socket, Transport, Opts]),
	{ok, Pid}.

%% FSM.

%% @private
-spec init(pid(), inet:socket(), module(), any()) -> ok.
init(ListenerPid, Socket, Transport, Opts) ->
	Dispatch = proplists:get_value(dispatch, Opts, []),
	MaxEmptyLines = proplists:get_value(max_empty_lines, Opts, 5),
	Timeout = proplists:get_value(timeout, Opts, 5000),
	receive shoot -> ok end,
	wait_request(#state{listener=ListenerPid, socket=Socket, transport=Transport,
		dispatch=Dispatch, max_empty_lines=MaxEmptyLines, timeout=Timeout}).

%% @private
-spec parse_request(#state{}) -> ok.
%% @todo Use decode_packet options to limit length?
parse_request(State=#state{buffer=Buffer}) ->
	case erlang:decode_packet(http_bin, Buffer, []) of
		{ok, Request, Rest} -> request(Request, State#state{buffer=Rest});
		{more, _Length} -> wait_request(State);
		{error, _Reason} -> error_response(400, State)
	end.

-spec wait_request(#state{}) -> ok.
wait_request(State=#state{socket=Socket, transport=Transport,
		timeout=T, buffer=Buffer}) ->
	case Transport:recv(Socket, 0, T) of
		{ok, Data} -> parse_request(State#state{
			buffer= << Buffer/binary, Data/binary >>});
		{error, timeout} -> error_terminate(408, State);
		{error, closed} -> terminate(State)
	end.

-spec request({http_request, http_method(), http_uri(),
	http_version()}, #state{}) -> ok.
%% @todo We probably want to handle some things differently between versions.
request({http_request, _Method, _URI, Version}, State)
		when Version =/= {1, 0}, Version =/= {1, 1} ->
	error_terminate(505, State);
%% @todo We need to cleanup the URI properly.
request({http_request, Method, {abs_path, AbsPath}, Version},
		State=#state{socket=Socket, transport=Transport}) ->
	{Path, RawPath, Qs} = agilitycache_dispatcher:split_path(AbsPath),
	ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
	parse_header(#http_req{socket=Socket, transport=Transport,
		connection=ConnAtom, method=Method, version=Version,
		path=Path, raw_path=RawPath, raw_qs=Qs},
		State#state{connection=ConnAtom});
request({http_request, Method, {absoluteURI, http, RawHost, undefined, AbsPath}, Version},
    State=#state{socket=Socket, transport=Transport}) ->
  {Path, RawPath, Qs} = agilitycache_dispatcher:split_path(AbsPath),
  ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
  RawHost2 = agilitycache_http_protocol_parser:binary_to_lower(RawHost),
  case catch agilitycache_dispatcher:split_host(RawHost2) of 
    {Host, RawHost3, undefined} ->
      Port = agilitycache_http_protocol_parser:default_port(Transport:name()),
     parse_header(#http_req{socket=Socket, transport=Transport,
		connection=ConnAtom, method=Method, version=Version,
		path=Path, raw_path=RawPath, raw_qs=Qs,
		host=Host, raw_host=RawHost3, port=Port},
		State#state{connection=ConnAtom});

    {Host, RawHost3, Port} ->
      parse_header(#http_req{socket=Socket, transport=Transport,
		connection=ConnAtom, method=Method, version=Version,
		path=Path, raw_path=RawPath, raw_qs=Qs,
		host=Host, raw_host=RawHost3, port=Port},
		State#state{connection=ConnAtom});
    _ ->
      error_terminate(400, State)
  end;
  
request({http_request, Method, {absoluteURI, http, RawHost, Port, AbsPath}, Version},
    State=#state{socket=Socket, transport=Transport}) ->
    {Path, RawPath, Qs} = agilitycache_dispatcher:split_path(AbsPath),
    ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
    RawHost2 = agilitycache_http_protocol_parser:binary_to_lower(RawHost),
    case catch agilitycache_dispatcher:split_host(RawHost2) of
      {Host, RawHost3, undefined} ->
        parse_header(#http_req{socket=Socket, transport=Transport,
			connection=ConnAtom, method=Method, version=Version,
			path=Path, raw_path=RawPath, raw_qs=Qs,
			host=Host, raw_host=RawHost3, port=Port},
			State#state{connection=ConnAtom});

      {Host, RawHost3, Port2} ->
        parse_header(#http_req{socket=Socket, transport=Transport,
			connection=ConnAtom, method=Method, version=Version,
			path=Path, raw_path=RawPath, raw_qs=Qs,
			host=Host, raw_host=RawHost3, port=Port2},
			State#state{connection=ConnAtom});
      _ ->
        error_terminate(400, State)
    end;

request({http_request, Method, '*', Version},
		State=#state{socket=Socket, transport=Transport}) ->
	ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
	parse_header(#http_req{socket=Socket, transport=Transport,
		connection=ConnAtom, method=Method, version=Version,
		path='*', raw_path= <<"*">>, raw_qs= <<>>},
		State#state{connection=ConnAtom});
request({http_request, _Method, _URI, _Version}, State) ->
	error_terminate(501, State);
request({http_error, <<"\r\n">>},
		State=#state{req_empty_lines=N, max_empty_lines=N}) ->
	error_terminate(400, State);
request({http_error, <<"\r\n">>}, State=#state{req_empty_lines=N}) ->
	parse_request(State#state{req_empty_lines=N + 1});
request({http_error, _Any}, State) ->
	error_terminate(400, State).

-spec parse_header(#http_req{}, #state{}) -> ok.
parse_header(Req, State=#state{buffer=Buffer}) ->
	case erlang:decode_packet(httph_bin, Buffer, []) of
		{ok, Header, Rest} -> header(Header, Req, State#state{buffer=Rest});
		{more, _Length} -> wait_header(Req, State);
		{error, _Reason} -> error_response(400, State)
	end.

-spec wait_header(#http_req{}, #state{}) -> ok.
wait_header(Req, State=#state{socket=Socket,
		transport=Transport, timeout=T, buffer=Buffer}) ->
	case Transport:recv(Socket, 0, T) of
		{ok, Data} -> parse_header(Req, State#state{
			buffer= << Buffer/binary, Data/binary >>});
		{error, timeout} -> error_terminate(408, State);
		{error, closed} -> terminate(State)
	end.

-spec header({http_header, integer(), http_header(), any(), binary()}
	| http_eoh, #http_req{}, #state{}) -> ok.
header({http_header, _I, 'Host', _R, RawHost}, Req=#http_req{
		transport=Transport, host=undefined}, State) ->
	RawHost2 = agilitycache_http_protocol_parser:binary_to_lower(RawHost),
	case catch agilitycache_dispatcher:split_host(RawHost2) of
		{Host, RawHost3, undefined} ->
			Port = agilitycache_http_protocol_parser:default_port(Transport:name()),
			dispatch(fun parse_header/2, Req#http_req{
				host=Host, raw_host=RawHost3, port=Port,
				headers=[{'Host', RawHost3}|Req#http_req.headers]}, State);
		{Host, RawHost3, Port} ->
			dispatch(fun parse_header/2, Req#http_req{
				host=Host, raw_host=RawHost3, port=Port,
				headers=[{'Host', RawHost3}|Req#http_req.headers]}, State);
		{'EXIT', _Reason} ->
			error_terminate(400, State)
	end;
%% Ignore Host headers if we already have it.
header({http_header, _I, 'Host', _R, _V}, Req, State) ->
	parse_header(Req, State);
header({http_header, _I, 'Connection', _R, Connection}, Req, State) ->
	ConnAtom = agilitycache_http_protocol_parser:connection_to_atom(Connection),
	parse_header(Req#http_req{connection=ConnAtom,
		headers=[{'Connection', Connection}|Req#http_req.headers]},
		State#state{connection=ConnAtom});
header({http_header, _I, Field, _R, Value}, Req, State) ->
	Field2 = agilitycache_http_protocol_parser:format_header(Field),
	parse_header(Req#http_req{headers=[{Field2, Value}|Req#http_req.headers]},
		State);
%% The Host header is required in HTTP/1.1.
header(http_eoh, #http_req{version={1, 1}, host=undefined}, State) ->
	error_terminate(400, State);
%% It is however optional in HTTP/1.0.
header(http_eoh, Req=#http_req{version={1, 0}, transport=Transport,
		host=undefined}, State=#state{buffer=Buffer}) ->
	Port = agilitycache_http_protocol_parser:default_port(Transport:name()),
	dispatch(fun handler_init/2, Req#http_req{host=[], raw_host= <<>>,
		port=Port, buffer=Buffer}, State#state{buffer= <<>>});
header(http_eoh, Req, State=#state{buffer=Buffer}) ->
	dispatch(fun handler_init/2, Req#http_req{buffer=Buffer}, State#state{buffer= <<>>});
header({http_error, _Bin}, _Req, State) ->
	error_terminate(500, State).

-spec dispatch(fun((#http_req{}, #state{}) -> ok),
	#http_req{}, #state{}) -> ok.
dispatch(Next, Req, State=#state{dispatch=Dispatch}) ->
	%% @todo We probably want to filter the Host and Path here to allow
  %%      other plugins...
	case agilitycache_dispatcher:match(Req, Dispatch) of
		{ok, Handler, Opts} ->
			Next(Req, State#state{handler={Handler, Opts}});
		{error, notfound} ->
			error_terminate(400, State)
	end.

-spec handler_init(#http_req{}, #state{}) -> ok.
handler_init(Req, State=#state{listener=ListenerPid,
		transport=Transport, handler={Handler, Opts}}) ->
	try Handler:init({Transport:name(), http}, Req, Opts) of
		{ok, Req2, HandlerState} ->
			handler_loop(HandlerState, Req2, State);
		%% @todo {upgrade, transport, Module}
		{upgrade, protocol, Module} ->
			Module:upgrade(ListenerPid, Handler, Opts, Req)
	catch Class:Reason ->
		error_terminate(500, State),
		error_logger:error_msg(
			"** Handler ~p terminating in init/3 for the reason ~p:~p~n"
			"** Options were ~p~n** Request was ~p~n** Stacktrace: ~p~n~n",
			[Handler, Class, Reason, Opts, Req, erlang:get_stacktrace()])
	end.

-spec handler_loop(any(), #http_req{}, #state{}) -> ok.
handler_loop(HandlerState, Req, State=#state{handler={Handler, Opts}}) ->
	try Handler:handle(Req#http_req{resp_state=waiting}, HandlerState) of
		{ok, Req2, HandlerState2} ->
			next_request(HandlerState2, Req2, State)
  %% @todo {upgrade, protocol, Module}
	catch Class:Reason ->
		error_logger:error_msg(
			"** Handler ~p terminating in handle/2 for the reason ~p:~p~n"
			"** Options were ~p~n** Handler state was ~p~n"
			"** Request was ~p~n** Stacktrace: ~p~n~n",
			[Handler, Class, Reason, Opts,
			 HandlerState, Req, erlang:get_stacktrace()]),
		handler_terminate(HandlerState, Req, State),
		terminate(State)
	end.

-spec handler_terminate(any(), #http_req{}, #state{}) -> ok | error.
handler_terminate(HandlerState, Req, #state{handler={Handler, Opts}}) ->
	try
		Handler:terminate(Req#http_req{resp_state=locked}, HandlerState)
	catch Class:Reason ->
		error_logger:error_msg(
			"** Handler ~p terminating in terminate/2 for the reason ~p:~p~n"
			"** Options were ~p~n** Handler state was ~p~n"
			"** Request was ~p~n** Stacktrace: ~p~n~n",
			[Handler, Class, Reason, Opts,
			 HandlerState, Req, erlang:get_stacktrace()]),
		error
	end.

-spec next_request(any(), #http_req{}, #state{}) -> ok.
next_request(HandlerState, Req=#http_req{buffer=Buffer}, State) ->
	HandlerRes = handler_terminate(HandlerState, Req, State),
	BodyRes = ensure_body_processed(Req),
	RespRes = ensure_response(Req, State),
	case {HandlerRes, BodyRes, RespRes, State#state.connection} of
		{ok, ok, ok, keepalive} ->
			?MODULE:parse_request(State#state{
				buffer=Buffer, req_empty_lines=0});
		_Closed ->
			terminate(State)
	end.

-spec ensure_body_processed(#http_req{}) -> ok | close.
ensure_body_processed(#http_req{body_state=done}) ->
	ok;
ensure_body_processed(Req=#http_req{body_state=waiting}) ->
	case agilitycache_http_req:body(Req) of
		{error, badarg} -> ok; %% No body.
		{error, _Reason} -> close;
		_Any -> ok
	end.

-spec ensure_response(#http_req{}, #state{}) -> ok.
%% The handler has already fully replied to the client.
ensure_response(#http_req{resp_state=done}, _State) ->
	ok;
%% No response has been sent but everything apparently went fine.
%% Reply with 204 No Content to indicate this.
ensure_response(#http_req{resp_state=waiting}, State) ->
	error_response(204, State);
%% Close the chunked reply.
ensure_response(#http_req{socket=Socket, transport=Transport,
		resp_state=chunks}, _State) ->
	Transport:send(Socket, <<"0\r\n\r\n">>),
	close.

-spec error_response(http_status(), #state{}) -> ok.
error_response(Code, #state{socket=Socket,
		transport=Transport, connection=Connection}) ->
	_ = agilitycache_http_req:reply(Code, [], [], #http_req{
		socket=Socket, transport=Transport,
		connection=Connection, resp_state=waiting}),
	ok.

-spec error_terminate(http_status(), #state{}) -> ok.
error_terminate(Code, State) ->
	error_response(Code, State#state{connection=close}),
	terminate(State).

-spec terminate(#state{}) -> ok.
terminate(#state{socket=Socket, transport=Transport}) ->
	Transport:close(Socket),
	ok.
