%%%-------------------------------------------------------------------
%%% @author Joaquim Pedro França Simão <>
%%% @copyright (C) 2012, Joaquim Pedro França Simão
%%% @doc
%%%
%%% @end
%%% Created : 15 Jun 2012 by Joaquim Pedro França Simão <>
%%%-------------------------------------------------------------------
-module(agilitycache_http_protocol).

-behaviour(gen_fsm).

%% API
-export([start_link/4]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).
-export([start_protocol_loop/4]).
-export([start_handle_request/3,
         read_reply/3,
         start_send_post/3,
         send_post/3,
         start_receive_reply/3,
         start_send_reply/3,
         do_basic_loop/3,
         send_reply/3,
         begin_stop/3,
         start_handle_req_keepalive_request/3,
         start_handle_both_keepalive_request/3,
         read_both_keepalive_reply/3
        ]).

-include("http.hrl").

-record(state, {
            http_server :: agilitycache_http_server:http_server_state(),
            http_client :: agilitycache_http_client:http_client_state() | undefined,
            listener :: pid(),
            transport :: module(),
            max_empty_lines = 5 :: integer(),
            timeout = 5000 :: timeout(),
            keepalive = both :: both | req | disabled,
            keepalive_default_timeout = 300 :: non_neg_integer(),
            keepalive_timeout = 0 :: timeout(),
            start_time = 0 :: integer(),
            restant = 0 :: integer()
           }).

-spec start_link(pid(), inet:socket(), module(), any()) ->
		                {ok, pid()}.
start_link(ListenerPid, Socket, Transport, Opts) ->
	Pid = spawn_link(?MODULE, start_protocol_loop,
	                 [ListenerPid, Socket, Transport, Opts]),
	{ok, Pid}.
-spec start_protocol_loop(pid(), inet:socket(), module(), any()) ->
		                         {ok, pid()} | ignore |
		                         {error, any()}.
start_protocol_loop(ListenerPid, Socket, Transport, Opts) ->
	{ok, Pid} = gen_fsm:start_link(?MODULE, {ListenerPid,
	                                         Socket,
	                                         Transport, Opts},
	                               []),
	%% ACK Cowboy
	cowboy:accept_ack(ListenerPid),
	protocol_loop(Pid).
protocol_loop(Pid) ->
	case gen_fsm:sync_send_event(Pid, simple, infinity) of
		ok ->
			ok;
		continue ->
			protocol_loop(Pid)
	end.

init({ListenerPid, ServerSocket, Transport, Opts}) ->

	%% Instrumentation
	folsom_metrics:notify({requests, 1}),
	StartTime = os:timestamp(),
	%% Options
	MaxEmptyLines = proplists:get_value(max_empty_lines, Opts, 5),
	%% If we couldn't send a message in Timeout time something
	%% is definitively wrong...
	Timeout = agilitycache_utils:get_app_env(tcp_timeout, 5000),
	BufferSize = agilitycache_utils:get_app_env(buffer_size,
	                                            87380),
	Transport:setopts(ServerSocket, [{send_timeout, Timeout},
	                                 {send_timeout_close, true},
	                                 {buffer, BufferSize},
	                                 {delay_send, true}]),
	HttpServer = agilitycache_http_server:new(Transport,
	                                          ServerSocket,
	                                          Timeout,
	                                          MaxEmptyLines),
	KeepAliveOpts = agilitycache_utils:get_app_env(keepalive,
	                                               [{type, both},
	                                                {max_timeout,
	                                                 300}]),
	KeepAlive = proplists:get_value(type, KeepAliveOpts, both),
	KeepAliveDefault = proplists:get_value(max_timeout,
	                                       KeepAliveOpts,
	                                       300),
	{ok, start_handle_request,
	 #state{http_server=HttpServer,
	        timeout=Timeout,
	        max_empty_lines=MaxEmptyLines,
	        transport=Transport,
	        listener=ListenerPid,
	        keepalive = KeepAlive,
	        keepalive_default_timeout = KeepAliveDefault,
	        start_time = StartTime}}.

%% Events

start_handle_request(_Event, _From,
                     #state{http_server=HttpServer} = State) ->
	{ok, HttpServer0} =
		agilitycache_http_server:read_request(HttpServer),
	{reply, continue, read_reply,
	 State#state{http_server=HttpServer0}}.

read_reply(_Event, _From,
           #state{http_server=HttpServer, transport=Transport,
                  timeout=Timeout,
                  max_empty_lines=MaxEmptyLines} = State) ->
	{HttpReq, HttpServer0} =
		agilitycache_http_server:get_http_req(HttpServer),
	HttpClient =
		agilitycache_http_client:new(Transport, Timeout,
		                             MaxEmptyLines),
	{ok, HttpReq0, HttpClient0} =
		agilitycache_http_client:start_request(HttpReq,
		                                       HttpClient),
	HttpServer1 =
		agilitycache_http_server:set_http_req(HttpReq0,
		                                      HttpServer0),
	Method =
		agilitycache_http_protocol_parser:method_to_binary(
		    HttpReq0#http_req.method),
	case Method of
		<<"POST">> ->
			{reply, continue, start_send_post,
			 State#state{http_server=HttpServer1,
			             http_client=HttpClient0}};
		_ ->
			{reply, continue, start_receive_reply,
			 State#state{http_server=HttpServer1,
			             http_client=HttpClient0}}
	end.
start_send_post(_Event, _From,
                #state{http_server=HttpServer} = State) ->
	{HttpReq, HttpServer0} =
		agilitycache_http_server:get_http_req(HttpServer),
	{Length, HttpReq2} =
		agilitycache_http_req:content_length(HttpReq),
	HttpServer1 =
		agilitycache_http_server:set_http_req(HttpReq2,
		                                      HttpServer0),
	case Length of
		_ when is_integer(Length) ->
			{reply, continue, send_post,
			 State#state{http_server=HttpServer1,
			             restant=Length}}
	end.
send_post(_Event, _From,
          #state{http_client=HttpClient,
                 http_server=HttpServer,
                 restant=Length} = State) ->
	{ok, Data, HttpServer0} =
		agilitycache_http_server:get_body(HttpServer),
	DataSize = iolist_size(Data),
	Restant = Length - DataSize,
	case Restant of
		0 ->
			{ok, HttpClient0} =
				agilitycache_http_client:send_data(
				    Data, HttpClient),
			{reply, continue, start_receive_reply,
			 State#state{http_client=HttpClient0,
			             http_server=HttpServer0}};
		_ when Restant > 0 ->
			{ok, HttpClient0} =
				agilitycache_http_client:send_data(
				    Data, HttpClient),
			{reply, continue, send_post,
			 State#state{http_client=HttpClient0,
			             http_server=HttpServer0,
			             restant=Restant}}
	end.
start_receive_reply(_Event, _From,
                    #state{http_client = HttpClient} = State) ->
	{ok, HttpClient0} =
		agilitycache_http_client:start_receive_reply(
		    HttpClient),
	{reply, continue, start_send_reply,
	 State#state{http_client=HttpClient0}}.
start_send_reply(_Event, _From,
                 #state{http_server=HttpServer,
                        http_client=HttpClient} = State) ->
	{HttpRep, HttpClient0} =
		agilitycache_http_client:get_http_rep(HttpClient),
	{Status, Rep2} = agilitycache_http_rep:status(HttpRep),
	{Headers, Rep3} = agilitycache_http_rep:headers(Rep2),
	{Length, Rep4} = agilitycache_http_rep:content_length(Rep3),
	{Req, HttpServer0} =
		agilitycache_http_server:get_http_req(HttpServer),
	{ok, Req2, HttpServer1} =
		agilitycache_http_req:start_reply(HttpServer0,
		                                  Status, Headers,
		                                  Length, Req),
	HttpClient1 = agilitycache_http_client:set_http_rep(
	                  Rep4, HttpClient0),
	HttpServer2 = agilitycache_http_server:set_http_req(
	                  Req2, HttpServer1),
	case Status of
		101 ->
			{reply, continue, do_basic_loop,
			 State#state{http_server=HttpServer2,
			             http_client=HttpClient1}};
		_ ->
			{reply, continue, send_reply,
			 State#state{http_server=HttpServer2,
			             http_client=HttpClient1,
			             restant=Length}}
	end.
do_basic_loop(_Event, _From,
              #state{http_server=HttpServer,
                     http_client=HttpClient,
                     transport=Transport} = State) ->
	ServerSocket =
		agilitycache_http_server:get_socket(HttpServer),
	ClientSocket =
		agilitycache_http_client:get_socket(HttpClient),
	Transport:setopts(ServerSocket,
	                  [{packet, 0}, {active, once}]),
	Transport:setopts(ClientSocket,
	                  [{packet, 0}, {active, once}]),

	receive
		{_, ServerSocket, Data} ->
			Transport:send(ClientSocket, Data),
			{reply, continue, do_basic_loop, State};
		{_, ClientSocket, Data} ->
			Transport:send(ServerSocket, Data),
			{reply, continue, do_basic_loop, State};
		{tcp_closed, ClientSocket} ->
			{HttpRep, HttpClient0} =
				agilitycache_http_client:get_http_rep(
				    HttpClient),
			HttpClient1 =
				agilitycache_http_client:set_http_rep(
				    HttpRep#http_rep{
				        connection=close},
				    HttpClient0),
			lager:debug("stopping"),
			{stop, normal, ok, State#state{
			                       http_client=HttpClient1}};
		{tcp_closed, ServerSocket} ->
			{HttpReq, HttpServer0} =
				agilitycache_http_server:get_http_req(
				    HttpServer),
			HttpServer1 =
				agilitycache_http_server:set_http_req(
				    HttpReq#http_req{
				        connection=close},
				    HttpServer0),
			lager:debug("stopping"),
			{stop, normal, ok, State#state{
			                       http_server=HttpServer1}}
	end.
send_reply(_Event, _From,
           #state{http_server=HttpServer,
                  http_client=HttpClient,
                  restant=Remaining} = State) ->
	{ok, Data, HttpClient0} =
		agilitycache_http_client:get_body(HttpClient),

	Size = iolist_size(Data),
	{Ended, NewRemaining} =
		case {Remaining, Size} of
			{_, 0} ->
				{true, Remaining};
			{undefined, _} ->
				{false, Remaining};
			_ when is_integer(Remaining) ->
				if
					Remaining - Size > 0 ->
						{false,
						 Remaining - Size};
					true ->
						%% @todo: fazer um strip quando der negativo
						{true,
						 Remaining - Size}
				end
		end,
	%%lager:debug("Ended: ~p, Remaining ~p, Size ~p,
	%% NewRemaining ~p", [Ended, Remaining, Size, NewRemaining]),
	{ok, HttpServer0} =
		agilitycache_http_server:send_data(Data, HttpServer),
	case Ended of
		true ->
			lager:debug("stopping"),
			{reply, continue, begin_stop, State#state{
			                                  http_server=HttpServer0,
			                                  http_client=HttpClient0}};
		false ->
			{reply, continue, send_reply,
			 State#state{http_server=HttpServer0,
			             http_client=HttpClient0,
			             restant=NewRemaining}}
	end.
begin_stop(_Event, _From, #state{keepalive=disabled} = State) ->
	{stop, normal, ok, State};
begin_stop(_Event, _From, #state{keepalive=KeepAliveType,
                                 http_server=HttpServer,
                                 http_client=HttpClient,
                                 keepalive_default_timeout=
	                                 KeepAliveDefaultTimeout,
                                 start_time=StartTime} = State) ->
	{HttpReq, HttpServer0} =
		agilitycache_http_server:get_http_req(HttpServer),
	{HttpRep, HttpClient0} =
		agilitycache_http_client:get_http_rep(HttpClient),

	case {KeepAliveType, HttpReq#http_req.connection,
	      HttpRep#http_rep.connection} of
		{both, keepalive, keepalive} ->
			ReqKeepAliveTimeout =
				agilitycache_http_protocol_parser:keepalive(
				    HttpReq#http_req.headers,
				    KeepAliveDefaultTimeout)*1000,
			RepKeepAliveTimeout =
				agilitycache_http_protocol_parser:keepalive(
				    HttpRep#http_rep.headers,
				    KeepAliveDefaultTimeout)*1000,
			KeepAliveTimeout = min(ReqKeepAliveTimeout,
			                       RepKeepAliveTimeout),
			{ok, HttpServer1} =
				agilitycache_http_server:stop(
				    keepalive, HttpServer0),
			{ok, HttpClient1} =
				agilitycache_http_client:stop(
				    keepalive, HttpClient0),

			EndTime = os:timestamp(),
			folsom_metrics:notify(
			    {total_proxy_time,
			     timer:now_diff(EndTime, StartTime)}),
			{reply, continue,
			 start_handle_both_keepalive_request,
			 State#state{http_server=HttpServer1,
			             http_client=HttpClient1,
			             keepalive_timeout =
				             KeepAliveTimeout}};
		{_, keepalive, close} ->
			{ok, HttpServer1} =
				agilitycache_http_server:stop(
				    keepalive, HttpServer0),
			{ok, HttpClient1} =
				agilitycache_http_client:stop(
				    close, HttpClient0),
			HttpServer2 =
				agilitycache_http_server:set_http_req(
				    #http_req{}, HttpServer1), %% Vazio
			KeepAliveTimeout =
				agilitycache_http_protocol_parser:keepalive(
				    HttpReq#http_req.headers,
				    KeepAliveDefaultTimeout)*1000,
			EndTime = os:timestamp(),
			folsom_metrics:notify(
			    {total_proxy_time,
			     timer:now_diff(EndTime, StartTime)}),
			{reply, continue,
			 start_handle_req_keepalive_request,
			 #state{http_server=HttpServer2,
			        http_client=HttpClient1,
			        keepalive_timeout =
				        KeepAliveTimeout}};
		_ ->
			{stop, normal, ok, State}
	end.

start_handle_req_keepalive_request(_Event, _From, #state{
                                               http_server=HttpServer,
                                               keepalive_timeout =
	                                               KeepAliveTimeout} =
	                                   State) ->
	{ok, HttpServer0} =
		agilitycache_http_server:read_keepalive_request(
		    KeepAliveTimeout, HttpServer),
	{reply, continue, read_reply,
	 State#state{http_server=HttpServer0}}.

start_handle_both_keepalive_request(_Event, _From,
                                    #state{http_server=HttpServer,
                                           keepalive_timeout=KeepAliveTimeout} = State) ->
	case agilitycache_http_server:read_keepalive_request(
	         KeepAliveTimeout, HttpServer) of
		{ok, HttpServer0} ->
			{reply, continue, read_both_keepalive_reply,
			 State#state{http_server=HttpServer0}};
		{error, closed, HttpServer0} ->
			{reply, continue, read_reply,
			 State#state{http_server=HttpServer0}}
	end.

read_both_keepalive_reply(_Event, _From,
                          #state{http_server=HttpServer,
                                 http_client=HttpClient} = State) ->
	{HttpReq, HttpServer0} = agilitycache_http_server:get_http_req(HttpServer),
	{ok, HttpReq0, HttpClient0} = agilitycache_http_client:start_keepalive_request(HttpReq, HttpClient),
	HttpServer1 = agilitycache_http_server:set_http_req(HttpReq0, HttpServer0),
	Method =
		agilitycache_http_protocol_parser:method_to_binary(
		    HttpReq0#http_req.method),
	case Method of
		<<"POST">> ->
			{reply, continue, start_send_post,
			 State#state{http_server=HttpServer1,
			             http_client=HttpClient0}};
		_ ->
			{reply, continue, start_receive_reply,
			 State#state{http_server=HttpServer1,
			             http_client=HttpClient0}}
	end.

handle_event(_Event, StateName, State) ->
	{next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
	Reply = ok,
	{reply, Reply, StateName, State}.

handle_info(_Info, StateName, State) ->
	{next_state, StateName, State}.

terminate(_Reason, _StateName, #state{start_time=StartTime,
                                      http_server=HttpServer,
                                      http_client=HttpClient}) ->
	EndTime = os:timestamp(),
	folsom_metrics:notify({total_proxy_time,
	                       timer:now_diff(EndTime, StartTime)}),
	agilitycache_http_server:stop(close, HttpServer),
	agilitycache_http_client:stop(close, HttpClient),
	ok.

code_change(_OldVsn, StateName, State, _Extra) ->
	{ok, StateName, State}.
