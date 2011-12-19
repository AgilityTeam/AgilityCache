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
	  listener :: pid(),
	  server_socket :: inet:socket(),
	  client_socket :: inet:socket(),
	  transport :: module(),
	  req_empty_lines = 0 :: integer(),
    rep_empty_lines = 0 :: integer(),
	  max_empty_lines :: integer(),
	  timeout :: timeout(),
	  remaining_bytes = undefined,
    server_buffer,
    client_buffer
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
    unexpected(read_request, State),
    read_request(State).
    
read_request(State) ->
  wait_request(State).

wait_request(State=#state{server_socket=Socket, transport=Transport,
          timeout=T, server_buffer=Buffer}) ->
    unexpected(wait_request, State),
    case Transport:recv(Socket, 0, T) of
      {ok, Data} ->
        start_parse_request(State#state{server_buffer= << Buffer/binary, Data/binary >>});
      {error, timeout} ->
        {stop, {http_error, 408}, State};
      {error, closed} ->
        {stop, closed, State}
    end.

%% @todo Use decode_packet options to limit length?
start_parse_request(State=#state{server_buffer=Buffer}) ->
  unexpected(start_parse_request, State),
      case erlang:decode_packet(http_bin, Buffer, []) of
    {ok, Request, Rest} ->
        parse_request(Request, State#state{server_buffer=Rest});
    {more, _Length} ->
        wait_request(State);
    {error, _Reason} ->
        {stop, {http_error, 400}, State}
      end.
parse_request({http_request, Method, {abs_path, AbsPath}, Version}, State) ->
      {Path, RawPath, Qs} = agilitycache_dispatcher:split_path(AbsPath),
      ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
      start_parse_request_header(State#state{http_req=#http_req{
                  connection=ConnAtom, method=Method, version=Version,
                  path=Path, raw_path=RawPath, raw_qs=Qs}});
parse_request({http_request, Method, {absoluteURI, http, RawHost, RawPort, AbsPath}, Version},
          State=#state{transport=Transport}) ->
      {Path, RawPath, Qs} = agilitycache_dispatcher:split_path(AbsPath),
      ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
      RawHost2 = agilitycache_http_protocol_parser:binary_to_lower(RawHost),
      DefaultPort = agilitycache_http_protocol_parser:default_port(Transport:name()),
      State2 = case {RawPort, agilitycache_dispatcher:split_host(RawHost2)} of
       {DefaultPort, {Host, RawHost3, _}} ->
           State#state{http_req=#http_req{
                connection=ConnAtom, method=Method, version=Version,
                path=Path, raw_path=RawPath, raw_qs=Qs,
                host=Host, raw_host=RawHost3, port=DefaultPort,
                headers=[{'Host', RawHost3}]}};
       {_, {Host, RawHost3, DefaultPort}} ->
           State#state{http_req=#http_req{
                connection=ConnAtom, method=Method, version=Version,
                path=Path, raw_path=RawPath, raw_qs=Qs,
                host=Host, raw_host=RawHost3, port=DefaultPort,
                headers=[{'Host', RawHost3}]}};
       {undefined, {Host, RawHost3, undefined}} ->
           State#state{http_req=#http_req{
                connection=ConnAtom, method=Method, version=Version,
                path=Path, raw_path=RawPath, raw_qs=Qs,
                host=Host, raw_host=RawHost3, port=DefaultPort,
                headers=[{'Host', RawHost3}]}};
       {undefined, {Host, RawHost3, Port}} ->
           BinaryPort = list_to_binary(integer_to_list(Port)),
           State#state{http_req=#http_req{
                connection=ConnAtom, method=Method, version=Version,
                path=Path, raw_path=RawPath, raw_qs=Qs,
                host=Host, raw_host=RawHost3, port=Port,
                headers=[{'Host', << RawHost3/binary, ":", BinaryPort/binary>>}]}};
       {Port, {Host, RawHost3, _}} ->
           BinaryPort = list_to_binary(integer_to_list(Port)),
           State#state{http_req=#http_req{
                connection=ConnAtom, method=Method, version=Version,
                path=Path, raw_path=RawPath, raw_qs=Qs,
                host=Host, raw_host=RawHost3, port=Port,
                headers=[{'Host', << RawHost3/binary, ":", BinaryPort/binary >>}]}};
       _ ->
           {stop, {http_error, 400}, State}
  
         end,
      case State2 of
    {stop, _, _} ->
        State2;
    _ ->
        start_parse_request_header(State2)
      end;
parse_request({http_request, _Method, _URI, _Version}, State) ->
  {stop, {http_error, 501}, State};
parse_request({http_error, <<"\r\n">>},
    State=#state{req_empty_lines=N, max_empty_lines=N}) ->
    {stop, {http_error, 400}, State};
parse_request({http_error, <<"\r\n">>}, State=#state{req_empty_lines=N}) ->
  start_parse_request(State#state{req_empty_lines=N + 1});
parse_request({http_error, _Any}, State) ->
  {stop, {http_error, 400}, State};
parse_request(Shit, State) ->
  unexpected(Shit, State),
  {stop, {http_error, 500}, State}.

start_parse_request_header(State=#state{server_buffer=Buffer}) ->
  unexpected(start_parse_request_header, State),
  case erlang:decode_packet(httph_bin, Buffer, []) of
    {ok, Header, Rest} ->
        parse_request_header(Header, State#state{server_buffer=Rest});
    {more, _Length} ->
        wait_request_header(State);
    {error, _Reason} ->
        {stop, {http_error, 400}, State}
    end.

wait_request_header(State=#state{server_socket=Socket, transport=Transport, timeout=T, server_buffer=Buffer}) ->
  case Transport:recv(Socket, 0, T) of
    {ok, Data} ->
      start_parse_request_header(State#state{server_buffer= << Buffer/binary, Data/binary >>});
    {error, timeout} ->
      {stop, {http_error, 408}, State};
    {error, closed} ->
      {stop, {http_error, 500}, State}
  end.

parse_request_header({http_header, _I, 'Host', _R, RawHost},
    State = #state{transport=Transport, http_req=Req=#http_req{host=undefined}}) ->
    RawHost2 = agilitycache_http_protocol_parser:binary_to_lower(RawHost),
    DefaultPort = agilitycache_http_protocol_parser:default_port(Transport:name()),
    State2 = case agilitycache_dispatcher:split_host(RawHost2) of
      {Host, RawHost3, DefaultPort} ->
        State#state{http_req=Req#http_req{
            host=Host, raw_host=RawHost3, port=DefaultPort,
            headers=[{'Host', RawHost3}|Req#http_req.headers]}};
      {Host, RawHost3, undefined} ->
        State#state{http_req=Req#http_req{
            host=Host, raw_host=RawHost3, port=DefaultPort,
            headers=[{'Host', RawHost3}|Req#http_req.headers]}};
      {Host, RawHost3, Port}->
        BinaryPort = list_to_binary(integer_to_list(Port)),
        State#state{http_req=Req#http_req{
            host=Host, raw_host=RawHost3, port=Port,
            headers=[{'Host', << RawHost3/binary, ":", BinaryPort/binary>>}|Req#http_req.headers]}};
      _ ->
        {stop, {http_error, 400}, State}
    end,
    case State2 of
      {stop, _, _} ->
        State2;
      _ ->
        start_parse_request_header(State2)
    end;
%% Ignore Host headers if we already have it.
parse_request_header({http_header, _I, 'Host', _R, _V}, State) ->
  start_parse_request_header(State);
parse_request_header({http_header, _I, 'Connection', _R, Connection}, State = #state{http_req=Req}) ->
  ConnAtom = agilitycache_http_protocol_parser:connection_to_atom(Connection),
  start_parse_request_header(State#state{http_req=Req#http_req{connection=ConnAtom,
        headers=[{'Connection', Connection}|Req#http_req.headers]}});
parse_request_header({http_header, _I, Field, _R, Value}, State = #state{http_req=Req}) ->
  Field2 = agilitycache_http_protocol_parser:format_header(Field),
  start_parse_request_header(State#state{http_req=Req#http_req{headers=[{Field2, Value}|Req#http_req.headers]}});
%% The Host header is required in HTTP/1.1.
parse_request_header(http_eoh, State=#state{http_req=Req}) when Req#http_req.version=:= {1, 1} andalso Req#http_req.host=:=undefined ->
  {stop, {http_error, 400}, State};
%% It is however optional in HTTP/1.0.
%% @todo Devia ser um erro, host undefined o.O
parse_request_header(http_eoh, State=#state{transport=Transport, http_req=Req=#http_req{version={1, 0}, host=undefined}}) ->
  Port = agilitycache_http_protocol_parser:default_port(Transport:name()),
  %% Ok, terminar aqui, e esperar envio!
  read_reply(State#state{http_req=Req#http_req{host=[], raw_host= <<>>, port=Port}});
parse_request_header(http_eoh, State) ->
  %% Ok, terminar aqui, e esperar envio!
  read_reply(State);
parse_request_header({http_error, _Bin}, State) ->
  {stop, {http_error, 500}, State}.

read_reply(State) ->
    unexpected(read_reply, State),
    start_request(State).

start_request(State=#state{http_req = HttpReq, transport = Transport, timeout = Timeout}) ->
  {RawHost, HttpReq0} = agilitycache_http_req:raw_host(HttpReq),
  {Port, HttpReq1} = agilitycache_http_req:port(HttpReq0),
  case Transport:connect(binary_to_list(RawHost), Port, [{buffer, 87380}], Timeout) of
    {ok, Socket} ->
      ok = Transport:controlling_process(Socket, self()),
      start_send_request(State#state{http_req = HttpReq1, client_socket = Socket});
    {error, Reason} ->
      {stop, {error, Reason}, State}
  end.

start_send_request(State = #state{client_socket=Socket, transport=Transport, http_req=HttpReq}) ->
  Packet = agilitycache_http_req:request_head(HttpReq),
  case Transport:send(Socket, Packet) of
    ok ->
      receive_reply(State);
    {error, Reason} ->
      {stop, {error, Reason}, State}
  end.

receive_reply(State = #state{http_req = #http_req{method = Method}}) ->
  case agilitycache_http_protocol_parser:method_to_binary(Method) of
    <<"POST">> ->
      start_send_post(State);
    _ ->
      start_receive_reply(State)
  end.
	
start_send_post(State = #state{http_req=Req}) ->
  unexpected(start_send_post, State),
	{Length, Req2} = agilitycache_http_req:content_length(Req),
	case Length of
		undefined ->
			{stop, {error, <<"POST without length">>}, State#state{http_req=Req2}};
		_ when is_binary(Length) ->
			send_post(list_to_integer(binary_to_list(Length)), State#state{http_req=Req2});
		_ when is_integer(Length) ->
			send_post(Length, State#state{http_req=Req2})
	end.

%% Empty buffer
get_server_body(State=#state{
        server_socket=Socket, transport=Transport, timeout=T, server_buffer= <<>>})->
      case Transport:recv(Socket, 0, T) of
        {ok, Data} ->
          {ok, Data, State};
        {error, timeout} ->
          timeout;
        {error, closed} ->
          closed;
        Other ->
          Other
      end;
%% Non empty buffer
get_server_body(State=#state{server_buffer=Buffer})->
  {ok, Buffer, State#state{server_buffer = <<>>}}.

  %% Empty buffer
get_client_body(State=#state{
        client_socket=Socket, transport=Transport, timeout=T, client_buffer= <<>>})->
      case Transport:recv(Socket, 0, T) of
        {ok, Data} ->          
          {ok, Data, State};         
        {error, timeout} ->
          timeout;
        {error, closed} ->
          closed;
        Other ->          
          Other
      end;
%% Non empty buffer
get_client_body(State=#state{client_buffer=Buffer})->
  {ok, Buffer, State#state{client_buffer = <<>>}}.


send_post(Length, State = #state{client_socket = ClientSocket, transport = Transport}) ->
		%% Esperamos que isso seja sucesso, então deixa dar pau se não for sucesso
    {ok, Data, State2} = get_server_body(State),
    DataSize = iolist_size(Data),
		Restant = Length - DataSize,
		case Restant of
			0 ->
        case Transport:send(ClientSocket, Data) of
          ok ->
            start_receive_reply(State2);                    
          {error, closed} ->
            %% @todo Eu devia alertar sobre isso, não?
            {stop, normal, State2};
          {error, Reason} ->
            {stop, {error, Reason}, State2}
        end;
			_ when Restant > 0 ->
				case Transport:send(ClientSocket, Data) of
            ok ->      
              send_post(Restant, State);                    
            {error, closed} ->
              %% @todo Eu devia alertar sobre isso, não?
              {stop, normal, State};
            {error, Reason} ->
              {stop, {error, Reason}, State}
          end;
			_ ->
				{stop, {error, <<"POST with incomplete data">>}, State}
		end.

start_receive_reply(State) ->
  unexpected(start_receive_reply, State),
  start_parse_reply(State).

start_parse_reply(State=#state{client_buffer=Buffer}) ->
    case erlang:decode_packet(http_bin, Buffer, []) of
  {ok, Reply, Rest} ->
      parse_reply({Reply, State#state{client_buffer=Rest}});
  {more, _Length} ->
      wait_reply(State);
  {error, Reason} ->
      {stop, {error, Reason}, State}
    end.

wait_reply(State = #state{client_socket=Socket, transport=Transport,
        timeout=T, client_buffer=Buffer}) ->
    case Transport:recv(Socket, 0, T) of
        {ok, Data} ->
      start_parse_reply(State#state{client_buffer= << Buffer/binary, Data/binary >>});
        {error, Reason} ->
      {stop, {error, Reason}, State}
    end.

parse_reply({{http_response, Version, Status, String}, State}) ->
    ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
    start_parse_reply_header(
      State#state{http_rep=#http_rep{connection=ConnAtom, status=Status, version=Version, string=String}}
     );
parse_reply({{http_error, <<"\r\n">>}, State=#state{rep_empty_lines=_N, max_empty_lines=_N}}) ->
    {stop, {http_error, 400}, State};
parse_reply({_Data={http_error, <<"\r\n">>}, State=#state{rep_empty_lines=N}}) ->
  start_parse_reply(State#state{rep_empty_lines=N + 1});
parse_reply({{http_error, _Any}, State}) ->
    {stop, {http_error, 400}, State}.

start_parse_reply_header(State=#state{client_buffer=Buffer}) ->
    case erlang:decode_packet(httph_bin, Buffer, []) of
  {ok, Header, Rest} ->
      parse_reply_header({Header, State#state{client_buffer=Rest}});
  {more, _Length} ->
      wait_reply_header(State);
  {error, _Reason} ->
      {stop, {http_error, 400}, State}
    end.

wait_reply_header(State=#state{client_socket=Socket,
    transport=Transport, timeout=T, client_buffer=Buffer}) ->
  case Transport:recv(Socket, 0, T) of
    {ok, Data} ->
      start_parse_reply_header(State#state{client_buffer= << Buffer/binary, Data/binary >>});
    {error, Reason} ->
      {stop, {error, Reason}, State}
  end.

parse_reply_header({{http_header, _I, 'Connection', _R, Connection}, State=#state{http_rep=Rep}}) ->
    ConnAtom = agilitycache_http_protocol_parser:connection_to_atom(Connection),
    start_parse_reply_header(
      State#state{
        http_rep=Rep#http_rep{connection=ConnAtom,
          headers=[{'Connection', Connection}|Rep#http_rep.headers]
        }});
parse_reply_header({{http_header, _I, Field, _R, Value}, State=#state{http_rep=Rep}}) ->
    Field2 = agilitycache_http_protocol_parser:format_header(Field),
    start_parse_reply_header(
      State#state{http_rep=Rep#http_rep{headers=[{Field2, Value}|Rep#http_rep.headers]}});
parse_reply_header({http_eoh, State}) ->
    %%  OK, esperar pedido do cliente.
    start_send_reply(State);
parse_reply_header({{http_error, _Bin}, State}) ->
    {stop, {http_error, 500}, State}.

start_send_reply(State = #state{http_req=#http_req{method='HEAD'}}) -> %% Head, pode finalizar...
  {stop, normal, State};
start_send_reply(State = #state{http_req=Req, http_rep=Rep, transport=Transport, server_socket=ServerSocket}) ->
  {Status, Rep2} = agilitycache_http_rep:status(Rep),
  {Headers, Rep3} = agilitycache_http_rep:headers(Rep2),
  {Length, Rep4} = agilitycache_http_rep:content_length(Rep3),
  {ok, Req2} = agilitycache_http_req:start_reply(Transport, ServerSocket, Status, Headers, Length, Req),
  Remaining = case Length of
    undefined -> undefined;
    _ when is_binary(Length) ->
      list_to_integer(binary_to_list(Length));
    _ when is_integer(Length) -> Length
  end,
  send_reply(Remaining, State#state{http_rep=Rep4, http_req=Req2}).
  
send_reply(Remaining, State = #state{server_socket=ServerSocket, transport=Transport}) ->
    %% Bem... oo servidor pode fechar, e isso não nos afeta muito, então
    %% gerencia aqui se fechar/timeout.
	case get_client_body(State) of
		{ok, Data, State2} ->
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
          case Transport:send(ServerSocket, Data) of
            ok ->
              {stop, normal, State2}; %% É o fim...
            {error, closed} ->
              %% @todo Eu devia alertar sobre isso, não?
              {stop, normal, State};
            {error, Reason} ->
              {stop, {error, Reason}, State}
          end;
				false ->
					case Transport:send(ServerSocket, Data) of
              ok ->      
                send_reply(NewRemaining, State2);
              {error, closed} ->
                %% @todo Eu devia alertar sobre isso, não?
                {stop, normal, State};
              {error, Reason} ->
                {stop, {error, Reason}, State}
            end
			end;
		closed -> 
			{stop, normal, State};
		timeout ->
			%% {stop, {error, <<"Remote Server timeout">>}, State} %% Não quero reportar sempre que o servidor falhar conosco...
      {stop, normal, State}
	end.

start_stop(State = #state{transport=Transport, server_socket=ServerSocket, client_socket=ClientSocket}) ->
  unexpected(start_stop, State),
  Transport:close(ServerSocket),
  Transport:close(ClientSocket).

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
