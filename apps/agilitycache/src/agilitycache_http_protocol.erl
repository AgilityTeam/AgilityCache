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
%% @see agilitycache_http_handler
-module(agilitycache_http_protocol).

-export([start_link/4]). %% API.
-export([init/4]). %% FSM.

-include("http.hrl").

-record(state, {
            http_client :: agilitycache_http_client:http_client_state() | undefined,
            http_server :: agilitycache_http_server:http_server_state() | undefined,
            listener :: pid(),
            transport :: module(),
            max_empty_lines = 5 :: integer(),
            timeout = 5000 :: timeout(),
            keepalive = both :: both | req | disabled,
            keepalive_default_timeout = 300 :: non_neg_integer(),
            start_time = 0 :: integer()
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

init(ListenerPid, ServerSocket, Transport, Opts) ->
	folsom_metrics:notify({requests, 1}),
	StartTime = os:timestamp(),
	MaxEmptyLines = proplists:get_value(max_empty_lines, Opts, 5),
	Timeout = agilitycache_utils:get_app_env(agilitycache, tcp_timeout, 5000),
	cowboy:accept_ack(ListenerPid),
	BufferSize = agilitycache_utils:get_app_env(agilitycache, buffer_size, 87380),
	Transport:setopts(ServerSocket, [
                                                %{nodelay, true}%, %% We want to be informed even when packages are small
	                                 {send_timeout, Timeout}, %% If we couldn't send a message in Timeout time something is definitively wrong...
	                                 {send_timeout_close, true}, %%... and therefore the connection should be closed
	                                 {buffer, BufferSize},
	                                 {delay_send, true}
	                                ]),
	%%lager:debug("ServerSocket buffer ~p",
	%%  [inet:getopts(ServerSocket, [delay_send])]),
	HttpServer = agilitycache_http_server:new(Transport, ServerSocket, Timeout, MaxEmptyLines),
	KeepAliveOpts = agilitycache_utils:get_app_env(agilitycache, keepalive, [{type, both}, {max_timeout, 300}]),
	KeepAlive = proplists:get_value(type, KeepAliveOpts, both),
	KeepAliveDefaultTimeout = proplists:get_value(max_timeout, KeepAliveOpts, 300),
	start_handle_request(#state{http_server=HttpServer, timeout=Timeout, max_empty_lines=MaxEmptyLines, transport=Transport,
	                            listener=ListenerPid, keepalive = KeepAlive, keepalive_default_timeout = KeepAliveDefaultTimeout,
	                            start_time = StartTime}).

-spec start_handle_request(#state{}) -> 'ok'.
start_handle_request(#state{http_server=HttpServer} = State) ->
                                                %lager:debug("~p Nova requisição start_handle_request...~n", [self()]),
	case agilitycache_http_server:read_request(HttpServer) of
		{ok, HttpServer0} ->
			read_reply(State#state{http_server=HttpServer0});
		{error, Reason, HttpServer1} ->
			start_stop({error, Reason}, State#state{http_server=HttpServer1})
	end.

-spec start_handle_req_keepalive_request(non_neg_integer(),#state{}) -> 'ok'.
start_handle_req_keepalive_request(KeepAliveTimeout, #state{http_server=HttpServer} = State) ->                                                %%lager:debug("~p Nova requisição start_handle_req_keepalive_request...~n", [self()]),
	case agilitycache_http_server:read_keepalive_request(KeepAliveTimeout, HttpServer) of
		{ok, HttpServer0} ->
			read_reply(State#state{http_server=HttpServer0});
		{error, Reason, HttpServer1} ->
			start_stop({error, Reason}, State#state{http_server=HttpServer1})
	end.

-spec start_handle_both_keepalive_request(non_neg_integer(),#state{}) -> 'ok'.
start_handle_both_keepalive_request(KeepAliveTimeout, #state{http_server=HttpServer} = State) ->
	%%lager:debug("~p Nova requisição start_handle_both_keepalive_request...~n", [self()]),
	case agilitycache_http_server:read_keepalive_request(KeepAliveTimeout, HttpServer) of
		{ok, HttpServer0} ->
			read_both_keepalive_reply(State#state{http_server=HttpServer0});
		{error, closed, HttpServer1} ->
			read_reply(State#state{http_server=HttpServer1});
		{error, Reason, HttpServer1} ->
			start_stop({error, Reason}, State#state{http_server=HttpServer1})
	end.

-spec read_both_keepalive_reply(#state{}) -> 'ok'.
read_both_keepalive_reply(#state{http_server=HttpServer, http_client=HttpClient} = State) ->
	{HttpReq, HttpServer0} = agilitycache_http_server:get_http_req(HttpServer),
	{ok, HttpReq0, HttpClient0} = agilitycache_http_client:start_keepalive_request(HttpReq, HttpClient),
	HttpServer1 = agilitycache_http_server:set_http_req(HttpReq0, HttpServer0),
	case agilitycache_http_protocol_parser:method_to_binary(HttpReq0#http_req.method) of
		<<"POST">> ->
			start_send_post(State#state{http_server=HttpServer1, http_client=HttpClient0});
		_ ->
			start_receive_reply(State#state{http_server=HttpServer1, http_client=HttpClient0})
	end.


-spec read_reply(#state{}) -> 'ok'.
read_reply(#state{http_server=HttpServer, transport=Transport, timeout=Timeout, max_empty_lines=MaxEmptyLines} = State) ->
	{HttpReq, HttpServer0} = agilitycache_http_server:get_http_req(HttpServer),
	HttpClient = agilitycache_http_client:new(Transport, Timeout, MaxEmptyLines),
	{ok, HttpReq0, HttpClient0} = agilitycache_http_client:start_request(HttpReq, HttpClient),
	HttpServer1 = agilitycache_http_server:set_http_req(HttpReq0, HttpServer0),
	case agilitycache_http_protocol_parser:method_to_binary(HttpReq0#http_req.method) of
		<<"POST">> ->
			start_send_post(State#state{http_server=HttpServer1, http_client=HttpClient0});
		_ ->
			start_receive_reply(State#state{http_server=HttpServer1, http_client=HttpClient0})
	end.

-spec start_send_post(#state{}) -> 'ok'.
start_send_post(State = #state{http_server=HttpServer}) ->
	{HttpReq, HttpServer0} = agilitycache_http_server:get_http_req(HttpServer),
	{Length, HttpReq2} = agilitycache_http_req:content_length(HttpReq),
	HttpServer1 = agilitycache_http_server:set_http_req(HttpReq2, HttpServer0),
	State2 = State#state{http_server=HttpServer1},
	case Length of
		undefined ->
			start_stop({error, <<"POST without length">>}, State2);
		_ when is_integer(Length) ->
			send_post(Length, State2)
	end.

-spec send_post(number(),#state{}) -> 'ok'.
send_post(Length, State = #state{http_client=HttpClient, http_server=HttpServer}) ->
	%% Esperamos que isso seja sucesso, então deixa dar pau se não for sucesso
	{ok, Data, HttpServer0} = agilitycache_http_server:get_body(HttpServer),
	DataSize = iolist_size(Data),
	Restant = Length - DataSize,
	case Restant of
		0 ->
			case agilitycache_http_client:send_data(Data, HttpClient) of
				{ok, HttpClient0} ->
					start_receive_reply(State#state{http_client=HttpClient0, http_server=HttpServer0});
				{error, closed, HttpClient0} ->
					%% @todo Eu devia alertar sobre isso, não?
					start_stop(normal, State#state{http_client=HttpClient0, http_server=HttpServer0});
				{error, Reason, HttpClient0} ->
					start_stop({error, Reason}, State#state{http_client=HttpClient0, http_server=HttpServer0})
			end;
		_ when Restant > 0 ->
			case agilitycache_http_client:send_data(Data, HttpClient) of
				{ok, HttpClient0} ->
					send_post(Restant, State#state{http_client=HttpClient0, http_server=HttpServer0});
				{error, closed, HttpClient0} ->
					%% @todo Eu devia alertar sobre isso, não?
					start_stop(normal, State#state{http_client=HttpClient0, http_server=HttpServer0});
				{error, Reason, HttpClient0} ->
					start_stop({error, Reason}, State#state{http_client=HttpClient0, http_server=HttpServer0})
			end;
		_ ->
			start_stop({error, <<"POST with incomplete data">>}, State)
	end.

-spec start_receive_reply(#state{}) -> no_return().
start_receive_reply(State = #state{http_client = HttpClient}) ->
	case agilitycache_http_client:start_receive_reply(HttpClient) of
		{ok, HttpClient0} ->
			start_send_reply(State#state{http_client=HttpClient0});
		Error ->
			start_stop(Error, State)
	end.

-spec start_send_reply(#state{}) -> no_return().
start_send_reply(State = #state{http_server=HttpServer, http_client=HttpClient}) ->
	{HttpRep, HttpClient0} = agilitycache_http_client:get_http_rep(HttpClient),
	{Status, Rep2} = agilitycache_http_rep:status(HttpRep),
	{Headers, Rep3} = agilitycache_http_rep:headers(Rep2),
	{Length, Rep4} = agilitycache_http_rep:content_length(Rep3),
	{Req, HttpServer0} = agilitycache_http_server:get_http_req(HttpServer),
	case agilitycache_http_req:start_reply(HttpServer0, Status, Headers, Length, Req) of
		{ok, Req2, HttpServer1} ->
			Remaining = case Length of
				            undefined -> undefined;
				            _ when is_integer(Length) -> Length
			            end,
			HttpClient1 = agilitycache_http_client:set_http_rep(Rep4, HttpClient0),
			HttpServer2 = agilitycache_http_server:set_http_req(Req2, HttpServer1),
			send_reply(Remaining, State#state{http_server=HttpServer2, http_client=HttpClient1});
		{error, Reason, HttpServer1} ->
			start_stop({error, Reason}, State#state{http_server=HttpServer1})
	end.

-spec send_reply(_,#state{}) -> no_return().
send_reply(Remaining, State = #state{http_server=HttpServer, http_client=HttpClient}) ->
	%% Bem... oo servidor pode fechar, e isso não nos afeta muito, então
	%% gerencia aqui se fechar/timeout.
	case agilitycache_http_client:get_body(HttpClient) of
		{ok, Data, HttpClient0} ->
			Size = iolist_size(Data),
			{Ended, NewRemaining} = case {Remaining, Size} of
				                        {_, 0} ->
					                        {true, Remaining};
				                        {undefined, _} ->
					                        {false, Remaining};
				                        _ when is_integer(Remaining) ->
					                        if
						                        Remaining - Size > 0 ->
							                        {false, Remaining - Size};
						                        true ->
							                        %% @todo: fazer um strip quando der negativo
							                        {true, Remaining - Size}
					                        end
			                        end,
			%%lager:debug("Ended: ~p, Remaining ~p, Size ~p, NewRemaining ~p", [Ended, Remaining, Size, NewRemaining]),
			case Ended of
				true ->
					case agilitycache_http_server:send_data(Data, HttpServer) of
						{ok, HttpServer0} ->
							start_stop(normal, State#state{http_server=HttpServer0, http_client=HttpClient0}); %% É o fim...
						{error, closed, HttpServer0} ->
							%% @todo Eu devia alertar sobre isso, não?
							start_stop(normal, State#state{http_server=HttpServer0, http_client=HttpClient0});
						{error, Reason, HttpServer0} ->
							start_stop({error, Reason}, State#state{http_server=HttpServer0, http_client=HttpClient0})
					end;
				false ->
					case agilitycache_http_server:send_data(Data, HttpServer) of
						{ok, HttpServer0} ->
							send_reply(NewRemaining, State#state{http_server=HttpServer0, http_client=HttpClient0});
						{error, closed, HttpServer0} ->
							%% @todo Eu devia alertar sobre isso, não?
							start_stop(normal, State#state{http_server=HttpServer0, http_client=HttpClient0});
						{error, Reason, HttpServer0} ->
							start_stop({error, Reason}, State#state{http_server=HttpServer0, http_client=HttpClient0})
					end
			end;
		{error, closed, HttpClient0} ->
			start_stop(normal, State#state{http_client=HttpClient0});
		{error, timeout, HttpClient0} ->
			%%start_stop({error, <<"Remote Server timeout">>}, State#state{http_client=HttpClient0}) %% Não quero reportar sempre que o servidor falhar conosco...
			start_stop(normal, State#state{http_client=HttpClient0})
	end.

-spec start_stop(normal | {error,_}, #state{}) -> 'ok'.
start_stop(normal, State = #state{keepalive=disabled, start_time=StartTime}) ->
	EndTime = os:timestamp(),
	folsom_metrics:notify({total_proxy_time, timer:now_diff(EndTime, StartTime)}),
	lager:debug("Normal, keepalive disabled"),
	do_stop(State);
start_stop(normal, State = #state{http_server=HttpServer, http_client=HttpClient, timeout=Timeout, max_empty_lines=MaxEmptyLines, transport=Transport,
                                  listener=ListenerPid, keepalive=KeepAliveType, keepalive_default_timeout=KeepAliveDefaultTimeout,
                                  start_time=StartTime}) ->
	{HttpReq, HttpServer0} = agilitycache_http_server:get_http_req(HttpServer),
	{HttpRep, HttpClient0} = agilitycache_http_client:get_http_rep(HttpClient),
	case {KeepAliveType, HttpReq#http_req.connection, HttpRep#http_rep.connection} of
		{both, keepalive, keepalive} ->
			lager:debug("Keepalive both stop"),
			ReqKeepAliveTimeout = agilitycache_http_protocol_parser:keepalive(HttpReq#http_req.headers, KeepAliveDefaultTimeout)*1000,
			RepKeepAliveTimeout = agilitycache_http_protocol_parser:keepalive(HttpRep#http_rep.headers, KeepAliveDefaultTimeout)*1000,
			KeepAliveTimeout = min(ReqKeepAliveTimeout, RepKeepAliveTimeout),
			do_stop_server(keepalive, State),
			do_stop_client(keepalive, State),
			EndTime = os:timestamp(),
			folsom_metrics:notify({total_proxy_time, timer:now_diff(EndTime, StartTime)}),
			start_handle_both_keepalive_request(KeepAliveTimeout, #state{http_server=HttpServer0, http_client=HttpClient0,
			                                                             timeout=Timeout, max_empty_lines=MaxEmptyLines, transport=Transport,
			                                                             listener=ListenerPid, keepalive=true,
			                                                             keepalive_default_timeout=KeepAliveDefaultTimeout,
			                                                             start_time=os:timestamp()});
		{_, keepalive, close} ->
			lager:debug("Keepalive HttpServer stop"),
			do_stop_server(keepalive, State),
			do_stop_client(close, State),
			HttpServer2 = agilitycache_http_server:set_http_req(#http_req{}, HttpServer0), %% Vazio
			KeepAliveTimeout = agilitycache_http_protocol_parser:keepalive(HttpReq#http_req.headers, KeepAliveDefaultTimeout)*1000,
			EndTime = os:timestamp(),
			folsom_metrics:notify({total_proxy_time, timer:now_diff(EndTime, StartTime)}),
			start_handle_req_keepalive_request(KeepAliveTimeout, #state{http_server=HttpServer2, timeout=Timeout, max_empty_lines=MaxEmptyLines,
			                                                            transport=Transport, listener=ListenerPid, keepalive=true,
			                                                            keepalive_default_timeout=KeepAliveDefaultTimeout,
			                                                            start_time=os:timestap()});
		_ ->
			EndTime = os:timestamp(),
			folsom_metrics:notify({total_proxy_time, timer:now_diff(EndTime, StartTime)}),
			lager:debug("Normal stop"),
			do_stop(State)
	end;
start_stop(_Reason, State = #state{start_time=StartTime}) ->
	%%lager:debug("Fechando ~p, Reason: ~p, State: ~p~n", [self(), Reason, State]),
	EndTime = os:timestamp(),
	folsom_metrics:notify({total_proxy_time, timer:now_diff(EndTime, StartTime)}),
	do_stop(State).

-spec do_stop(#state{}) -> 'ok'.
do_stop(State) ->
	do_stop_client(close, State),
	do_stop_server(close, State),
	ok.
-spec do_stop_server(close | keepalive, #state{}) -> 'ok'.
do_stop_server(_Type, _State = #state{http_server=undefined}) ->
	ok;
do_stop_server(Type, _State = #state{http_server=HttpServer}) ->
	%%unexpected(start_stop, State),
	agilitycache_http_server:stop(Type, HttpServer),
	ok.
-spec do_stop_client(close | keepalive, #state{}) -> 'ok'.
do_stop_client(_Type, _State = #state{http_client=undefined}) ->
	ok;
do_stop_client(Type, _State = #state{http_client=HttpClient}) ->
	agilitycache_http_client:stop(Type, HttpClient),
	ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

