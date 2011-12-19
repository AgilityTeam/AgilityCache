-module(agilitycache_http_protocol_fsm).

-behaviour(gen_fsm).

%% API
-export([start_link/1, start/1]).

%% gen_fsm callbacks
-export([init/1,
         start_handle_request/2,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-export([start_handle_request/1,
		stop/1]).


-include("include/http.hrl").

-record(state, {
	  http_req :: #http_req{},
	  http_rep :: #http_rep{},
	  http_client :: pid(),
	  http_server :: pid(),
	  listener :: pid(),
	  server_socket :: inet:socket(),
	  client_socket :: inet:socket(),
	  transport :: module(),
	  req_empty_lines = 0 :: integer(),
	  max_empty_lines :: integer(),
	  timeout :: timeout(),
	  remaining_bytes = undefined
	 }).

%%%===================================================================
%%% API
%%%===================================================================

start_handle_request(OwnPid) ->
    gen_fsm:send_event(OwnPid, start).
    
stop(OwnPid) ->
    gen_fsm:send_all_state_event(OwnPid, stop).	 

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Opts) ->
        gen_fsm:start_link(?MODULE, Opts, []).
        
start(Opts) ->
        gen_fsm:start(?MODULE, Opts, []).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @spec init(Args) -> {ok, StateName, State} |
%%                     {ok, StateName, State, Timeout} |
%%                     ignore |
%%                     {stop, StopReason}
%% @end
%%--------------------------------------------------------------------
init(Opts) ->
	ListenerPid = proplists:get_value(listener, Opts),
	ServerSocket = proplists:get_value(socket, Opts),
	Transport = proplists:get_value(transport, Opts),
    MaxEmptyLines = proplists:get_value(max_empty_lines, Opts, 5),
    Timeout = proplists:get_value(timeout, Opts, 5000),
    HttpReq = proplists:get_value(http_req, Opts),
    Transport = proplists:get_value(transport, Opts),
    {ok, start_handle_request, #state{http_req=HttpReq, timeout=Timeout, max_empty_lines=MaxEmptyLines, transport=Transport,
    listener=ListenerPid, server_socket=ServerSocket}}.

start_handle_request(start, State) ->
    read_request(State).
    
read_request(State = #state{socket=Socket, transport=Transport,
			    max_empty_lines=MaxEmptyLines, timeout=Timeout}) ->
    {ok, HttpServerPid} = 
    {ok, Req} = agilitycache_http_protocol_server:receive_request(HttpServerPid),
    receive_reply(State#state{http_req=Req, http_server=HttpServerPid, http_server_ref=Ref}).

receive_reply(State = #state{transport=Transport, max_empty_lines=MaxEmptyLines, timeout=Timeout, http_req=Req}) ->
    {ok, HttpClientPid} = agilitycache_http_protocol_client:start([
						      {max_empty_lines, MaxEmptyLines}, 
						      {timeout, Timeout},
						      {transport, Transport},
						      {http_req, Req}]),
    Ref = erlang:monitor(process, HttpClientPid),
    {Method, Req2} = agilitycache_http_req:method(Req),
    agilitycache_http_protocol_client:start_request(HttpClientPid),
    case agilitycache_http_protocol_parser:method_to_binary(Method) of
		<<"POST">> ->
			start_send_post(State#state{http_client = HttpClientPid, http_req=Req2, http_client_ref=Ref});
		_ ->
			{ok, Rep} = agilitycache_http_protocol_client:start_receive_reply(HttpClientPid),
			start_send_reply(State#state{http_rep=Rep, http_client = HttpClientPid, http_req=Req2, http_client_ref=Ref})
	end.
	
start_send_post(State = #state{http_req=Req}) ->
	{Length, Req2} = agilitycache_http_req:content_length(Req),
	case Length of
		undefined ->
			{stop, {error, <<"POST without length">>}, State#state{http_req=Req2}};
		_ when is_binary(Length) ->
			send_post(list_to_integer(binary_to_list(Length)), State#state{http_req=Req2});
		_ when is_integer(Length) ->
			send_post(Length, State#state{http_req=Req2})
	end.
	
send_post(Length, State = #state{http_client = HttpClientPid, http_server = HttpServerPid}) ->
		%% Esperamos que isso seja sucesso, então deixa dar pau se não for sucesso
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
				{stop, {error, <<"POST with incomplete data">>}, State}
		end.
	

start_send_reply(State = #state{http_req=Req, http_rep=Rep, http_server=HttpServerPid}) ->
  {Status, Rep2} = agilitycache_http_rep:status(Rep),
  {Headers, Rep3} = agilitycache_http_rep:headers(Rep2),
  {Length, Rep4} = agilitycache_http_rep:content_length(Rep3),
  {ok, Req2} = agilitycache_http_req:start_reply(HttpServerPid, Status, Headers, Length, Req),
  Remaining = case Length of
	undefined -> undefined;
	_ when is_binary(Length) ->
		list_to_integer(binary_to_list(Length));
	_ when is_integer(Length) -> Length
	end,
  send_reply(State#state{http_rep=Rep4, http_req=Req2, remaining_bytes = Remaining}).
  
send_reply(State = #state{http_client = HttpClientPid, http_server = HttpServerPid, http_req=Req, remaining_bytes = Remaining}) ->
    %% Bem... oo servidor pode fechar, e isso não nos afeta muito, então
    %% gerencia aqui se fechar/timeout.
	case agilitycache_http_protocol_client:get_body(HttpClientPid) of
		{ok, Data} ->
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
            Remaining - Size == 0 ->
              {true, Remaining - Size}
          end
      end,
      %%error_logger:info_msg("Ended: ~p, Remaining ~p, Size ~p, NewRemaining ~p", [Ended, Remaining, Size, NewRemaining]),
      case Ended of
        true ->
          agilitycache_http_req:send_reply(HttpServerPid, Data, Req),
          {stop, normal, State#state{remaining_bytes = NewRemaining}};
				false ->
					agilitycache_http_req:send_reply(HttpServerPid, Data, Req),
					send_reply(State#state{remaining_bytes = NewRemaining})
			end;
		closed -> 
			{stop, normal, State};
		timeout ->
			%% {stop, {error, <<"Remote Server timeout">>}, State} %% Não quero reportar sempre que o servidor falhar conosco...
      {stop, normal, State}
	end.

start_stop(#state{http_client = HttpClientPid, http_client_ref=ClientRef,
                  http_server = HttpServerPid, http_server_ref=ServerRef}) ->
  %%unexpected("Olha eu fechanado...", start_stop),
  erlang:demonitor(ClientRef, [flush]),
  agilitycache_http_protocol_client:stop(HttpClientPid),
  erlang:demonitor(ServerRef, [flush]),
  agilitycache_http_protocol_server:stop(HttpServerPid).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @spec handle_event(Event, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_event(stop, _StateName, StateData) ->
    start_stop(StateData),
    {stop, normal, StateData};
handle_event(_Event, StateName, State) ->
        {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @spec handle_sync_event(Event, From, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, State) ->
        Reply = ok,
        {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @spec handle_info(Info,StateName,State)->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_info({'DOWN', Ref, process, Pid, Reason}, _StateName, State=#state{http_client=Pid, http_client_ref=Ref}) ->
    {stop, {error, <<"Http Client Dead">>, Reason}, State};
handle_info({'DOWN', Ref, process, Pid, Reason}, _StateName, State=#state{http_server=Pid, http_server_ref=Ref}) ->
    {stop, {error, <<"Http Server Dead">>, Reason}, State};
handle_info(Info, StateName, Data) ->
    unexpected(Info, StateName),
    {next_state, StateName, Data}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @spec terminate(Reason, StateName, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(shutdown, _StateName, State) ->
        start_stop(State),
        ok;
terminate(normal, _StateName, State) ->
    start_stop(State),
		ok; %% Já foi limpado no handle_event(stop, _StateName, StateData)
terminate(_Reason, _StateName, State) ->
        start_stop(State), %% Let crash...
        ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
        {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Unexpected allows to log unexpected messages
-spec unexpected(any(), atom()) -> ok.
unexpected(Msg, State) ->
    error_logger:info_msg("~p received unknown event ~p while in state ~p~n",
			  [self(), Msg, State]).
