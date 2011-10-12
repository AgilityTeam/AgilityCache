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
-export([init/4]). %% FSM.

-include("include/http.hrl").
-include_lib("eunit/include/eunit.hrl").

-record(state, {
	  http_req :: #http_req{},
	  http_rep :: #http_rep{},
	  http_client :: pid(),
	  http_server :: pid(),
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
    start_handle_request(#state{listener=ListenerPid, socket=Socket, transport=Transport,
				dispatch=Dispatch, max_empty_lines=MaxEmptyLines, timeout=Timeout}).

start_handle_request(State) ->
    read_request(State).

read_request(State = #state{socket=Socket, transport=Transport,
			    max_empty_lines=MaxEmptyLines, timeout=Timeout}) ->
    {ok, HttpServerPid} = 
	agilitycache_http_protocol_server:start([
						      {max_empty_lines, MaxEmptyLines}, 
						      {timeout, Timeout},
						      {transport, Transport},
						      {socket, Socket}]),
    {ok, Req} = agilitycache_http_protocol_server:receive_request(HttpServerPid),
    receive_reply(State#state{http_req=Req, http_server=HttpServerPid}).

receive_reply(State = #state{transport=Transport, max_empty_lines=MaxEmptyLines, timeout=Timeout, http_req=Req}) ->
    error_logger:info_msg("WTF o que eu to fazendo aqui? ~p:~p", [?MODULE, ?LINE]),
    {ok, HttpClientPid} = agilitycache_http_protocol_client:start([
						      {max_empty_lines, MaxEmptyLines}, 
						      {timeout, Timeout},
						      {transport, Transport},
						      {http_req, Req}]),
    error_logger:info_msg("WTF o que eu to fazendo aqui? ~p:~p", [?MODULE, ?LINE]),
    {Method, Req2} = agilitycache_http_req:method(Req),
    error_logger:info_msg("WTF o que eu to fazendo aqui? ~p:~p", [?MODULE, ?LINE]),
    agilitycache_http_protocol_client:start_request(HttpClientPid),
    error_logger:info_msg("WTF o que eu to fazendo aqui? ~p:~p", [?MODULE, ?LINE]),
    case agilitycache_http_protocol_parser:method_to_binary(Method) of
		<<"POST">> ->
			start_send_post(State#state{http_client = HttpClientPid, http_req=Req2});
		_ ->
			{ok, Rep} = agilitycache_http_protocol_client:start_receive_reply(HttpClientPid),
			start_send_reply(State#state{http_rep=Rep, http_client = HttpClientPid, http_req=Req2})
	end,
	error_logger:info_msg("WTF o que eu to fazendo aqui? ~p:~p", [?MODULE, ?LINE]).
	
start_send_post(State = #state{http_req=Req}) ->
	{Length, Req2} = agilitycache_http_req:content_length(Req),
	case Length of
		undefined ->
			start_stop(State#state{http_req=Req2});
		_ when is_binary(Length) ->
			send_post(list_to_integer(binary_to_list(Length)), State#state{http_req=Req2});
		_ when is_integer(Length) ->
			send_post(Length, State#state{http_req=Req2})
	end.
	
send_post(Length, State = #state{http_client = HttpClientPid, http_server = HttpServerPid}) ->
		{ok, Data} = agilitycache_http_protocol_server:get_body(HttpServerPid),
		DataSize = iolist_size(Data),
		Restant = Length - DataSize,
		case Restant of
			0 ->
				agilitycache_http_protocol_client:send_data(HttpClientPid, Data),
				{ok, Rep} = agilitycache_http_protocol_client:start_receive_reply(HttpClientPid),
				start_send_reply(State#state{http_rep=Rep});
			_ when Restant > 0 ->
				agilitycache_http_protocol_client:send_data(HttpClientPid, Data),
				send_post(Restant, State);
			_ ->
				start_stop(State)
		end.
	

start_send_reply(State = #state{http_req=Req, http_rep=Rep, http_server=HttpServerPid}) ->
  {Status, Rep2} = agilitycache_http_rep:status(Rep),
  {Headers, Rep3} = agilitycache_http_rep:headers(Rep2),
  {Length, Rep4} = agilitycache_http_rep:content_length(Rep3),
  {ok, Req2} = agilitycache_http_req:start_reply(HttpServerPid, Status, Headers, Length, Req),
  send_reply(State#state{http_rep=Rep4, http_req=Req2}).
  
send_reply(State = #state{http_client = HttpClientPid, http_server = HttpServerPid, http_req=Req}) ->
	{ok, Data} = agilitycache_http_protocol_client:get_body(HttpClientPid),
	case iolist_size(Data) of
		0 ->
			agilitycache_http_req:send_reply(HttpServerPid, Data, Req),
			start_stop(State);
		_ ->
			agilitycache_http_req:send_reply(HttpServerPid, Data, Req),
			send_reply(State)
	end.

start_stop(#state{http_client = HttpClientPid, http_server = HttpServerPid}) ->
	agilitycache_http_protocol_client:stop(HttpClientPid),
	agilitycache_http_protocol_server:stop(HttpServerPid).
