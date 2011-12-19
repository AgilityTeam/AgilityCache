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

-include("include/http.hrl").
-include_lib("eunit/include/eunit.hrl").

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
	  timeout = 5000 :: timeout(),
      server_buffer = <<>> :: binary(),
      client_buffer = <<>> :: binary()
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
    MaxEmptyLines = proplists:get_value(max_empty_lines, Opts, 5),
    Timeout = proplists:get_value(timeout, Opts, 5000),
	HttpReq = proplists:get_value(http_req, Opts),
    cowboy:accept_ack(ListenerPid),
    Transport:setopts(ServerSocket, [{buffer, 87380}]),
    %%error_logger:info_msg("ServerSocket buffer ~p,~p,~p", 
    %%  [inet:getopts(ServerSocket, [buffer]), inet:getopts(ServerSocket, [recbuf]), inet:getopts(ServerSocket, [sndbuf]) ]),
    start_handle_request(#state{http_req=HttpReq, timeout=Timeout, max_empty_lines=MaxEmptyLines, transport=Transport,
    	listener=ListenerPid, server_socket=ServerSocket}).

start_handle_request(State) ->
    read_request(State).
    
read_request(State) ->
  wait_request(State).

wait_request(State=#state{server_socket=Socket, transport=Transport,
          timeout=T, server_buffer=Buffer}) ->
    case Transport:recv(Socket, 0, T) of
      {ok, Data} ->
        State2 = State#state{server_buffer = << Buffer/binary, Data/binary>>},
        start_parse_request(State2);
      {error, timeout} ->
        start_stop({http_error, 408}, State);
      {error, closed} ->
        start_stop(closed, State)
    end.

%% @todo Use decode_packet options to limit length?
start_parse_request(State=#state{server_buffer=Buffer}) ->
      case erlang:decode_packet(http_bin, Buffer, []) of
    {ok, Request, Rest} ->
        parse_request(Request, State#state{server_buffer=Rest});
    {more, _Length} ->
      wait_request(State);
    {error, _Reason} ->
      start_stop({http_error, 400}, State)
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
      RawHost2 = cowboy_bstr:to_lower(RawHost),
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
           start_stop({http_error, 400}, State)
         end,
      case State2 of
    {stop, Reason, SubState} ->
              start_stop(Reason, SubState);
    _ ->
        start_parse_request_header(State2)
      end;
parse_request({http_request, _Method, _URI, _Version}, State) ->
  start_stop({http_error, 501}, State);
parse_request({http_error, <<"\r\n">>},
    State=#state{req_empty_lines=N, max_empty_lines=N}) ->
    start_stop({http_error, 400}, State);
parse_request({http_error, <<"\r\n">>}, State=#state{req_empty_lines=N}) ->
  start_parse_request(State#state{req_empty_lines=N + 1});
parse_request({http_error, _Any}, State) ->
  start_stop({http_error, 400}, State);
parse_request(Shit, State) ->
  unexpected(Shit, State),
  start_stop({http_error, 500}, State).

start_parse_request_header(State=#state{server_buffer=Buffer}) ->
  case erlang:decode_packet(httph_bin, Buffer, []) of
    {ok, Header, Rest} ->
        parse_request_header(Header, State#state{server_buffer=Rest});
    {more, _Length} ->
        wait_request_header(State);
    {error, _Reason} ->
        start_stop({http_error, 400}, State)
    end.

wait_request_header(State=#state{server_socket=Socket, transport=Transport, timeout=T, server_buffer=Buffer}) ->
  case Transport:recv(Socket, 0, T) of
    {ok, Data} ->
      start_parse_request_header(State#state{server_buffer= << Buffer/binary, Data/binary >>});
    {error, timeout} ->
      start_stop({http_error, 408}, State);
    {error, closed} ->
      start_stop({http_error, 500}, State)
  end.

parse_request_header({http_header, _I, 'Host', _R, RawHost},
    State = #state{transport=Transport, http_req=Req=#http_req{host=undefined}}) ->
    RawHost2 = cowboy_bstr:to_lower(RawHost),
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
        start_stop({http_error, 400}, State)
    end,
    case State2 of
      {stop, Reason, SubState} ->
        start_stop(Reason, SubState);
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
  start_stop({http_error, 400}, State);
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
  start_stop({http_error, 500}, State).

read_reply(State) ->
    start_request(State).

start_request(State=#state{http_req = HttpReq, transport = Transport, timeout = Timeout}) ->
  {RawHost, HttpReq0} = agilitycache_http_req:raw_host(HttpReq),
  {Port, HttpReq1} = agilitycache_http_req:port(HttpReq0),
  case Transport:connect(binary_to_list(RawHost), Port, [{buffer, 87380}], Timeout) of
    {ok, Socket} ->
      start_send_request(State#state{http_req = HttpReq1, client_socket = Socket});
    {error, Reason} ->
      start_stop({error, Reason}, State)
  end.

start_send_request(State = #state{client_socket=Socket, transport=Transport, http_req=HttpReq}) ->
  %%error_logger:info_msg("ClientSocket buffer ~p,~p,~p", 
  %%        [inet:getopts(Socket, [buffer]), inet:getopts(Socket, [recbuf]), inet:getopts(Socket, [sndbuf]) ]),
  Packet = agilitycache_http_req:request_head(HttpReq),
  case Transport:send(Socket, Packet) of
    ok ->
      receive_reply(State);
    {error, Reason} ->
      start_stop({error, Reason}, State)
  end.

receive_reply(State = #state{http_req = #http_req{method = Method}}) ->
  case agilitycache_http_protocol_parser:method_to_binary(Method) of
    <<"POST">> ->
      start_send_post(State);
    _ ->
      start_receive_reply(State)
  end.
	
start_send_post(State = #state{http_req=Req}) ->
	{Length, Req2} = agilitycache_http_req:content_length(Req),
	case Length of
		undefined ->
			start_stop({error, <<"POST without length">>}, State#state{http_req=Req2});
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
            start_stop(normal, State2);
          {error, Reason} ->
            start_stop({error, Reason}, State2)
        end;
			_ when Restant > 0 ->
				case Transport:send(ClientSocket, Data) of
            ok ->      
              send_post(Restant, State);                    
            {error, closed} ->
              %% @todo Eu devia alertar sobre isso, não?
              start_stop(normal, State);
            {error, Reason} ->
              start_stop({error, Reason}, State)
          end;
			_ ->
				start_stop({error, <<"POST with incomplete data">>}, State)
		end.

start_receive_reply(State) ->
  start_parse_reply(State).

start_parse_reply(State=#state{client_buffer=Buffer}) ->
    case erlang:decode_packet(http_bin, Buffer, []) of
  {ok, Reply, Rest} ->
      parse_reply({Reply, State#state{client_buffer=Rest}});
  {more, _Length} ->
      wait_reply(State);
  {error, Reason} ->
      start_stop({error, Reason}, State)
    end.

wait_reply(State = #state{client_socket=Socket, transport=Transport,
        timeout=T, client_buffer=Buffer}) ->
    case Transport:recv(Socket, 0, T) of
        {ok, Data} ->
      start_parse_reply(State#state{client_buffer= << Buffer/binary, Data/binary >>});
        {error, Reason} ->
      start_stop({error, Reason}, State)
    end.

parse_reply({{http_response, Version, Status, String}, State}) ->
    ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
    start_parse_reply_header(
      State#state{http_rep=#http_rep{connection=ConnAtom, status=Status, version=Version, string=String}}
     );
parse_reply({{http_error, <<"\r\n">>}, State=#state{rep_empty_lines=_N, max_empty_lines=_N}}) ->
    start_stop({http_error, 400}, State);
parse_reply({_Data={http_error, <<"\r\n">>}, State=#state{rep_empty_lines=N}}) ->
  start_parse_reply(State#state{rep_empty_lines=N + 1});
parse_reply({{http_error, _Any}, State}) ->
    start_stop({http_error, 400}, State).

start_parse_reply_header(State=#state{client_buffer=Buffer}) ->
    case erlang:decode_packet(httph_bin, Buffer, []) of
  {ok, Header, Rest} ->
      parse_reply_header({Header, State#state{client_buffer=Rest}});
  {more, _Length} ->
      wait_reply_header(State);
  {error, _Reason} ->
      start_stop({http_error, 400}, State)
    end.

wait_reply_header(State=#state{client_socket=Socket,
    transport=Transport, timeout=T, client_buffer=Buffer}) ->
  case Transport:recv(Socket, 0, T) of
    {ok, Data} ->
      start_parse_reply_header(State#state{client_buffer= << Buffer/binary, Data/binary >>});
    {error, Reason} ->
      start_stop({error, Reason}, State)
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
    start_stop({http_error, 500}, State).

start_send_reply(State = #state{http_req=#http_req{method='HEAD'}}) -> %% Head, pode finalizar...
  start_stop(normal, State);
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
              start_stop(normal, State2); %% É o fim...
            {error, closed} ->
              %% @todo Eu devia alertar sobre isso, não?
              start_stop(normal, State);
            {error, Reason} ->
              start_stop({error, Reason}, State)
          end;
				false ->
					case Transport:send(ServerSocket, Data) of
              ok ->      
                send_reply(NewRemaining, State2);
              {error, closed} ->
                %% @todo Eu devia alertar sobre isso, não?
                start_stop(normal, State);
              {error, Reason} ->
                start_stop({error, Reason}, State)
            end
			end;
		closed -> 
			start_stop(normal, State);
		timeout ->
			%% start_stop({error, <<"Remote Server timeout">>}, State) %% Não quero reportar sempre que o servidor falhar conosco...
      start_stop(normal, State)
	end.

start_stop(normal, State) ->
  do_stop(State);
start_stop(_Reason, State) ->
  %%error_logger:info_msg("Fechando ~p, Reason: ~p, State: ~p~n", [self(), Reason, State]),
  do_stop(State).

do_stop(_State = #state{transport=Transport, server_socket=ServerSocket, client_socket=ClientSocket}) ->
  %%unexpected(start_stop, State),
  case ServerSocket of
    undefined ->
      ok;
    _ ->
      Transport:close(ServerSocket)
  end,
  case ClientSocket of 
    undefined ->
      ok;
    _ ->
      Transport:close(ClientSocket)
  end.
%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Unexpected allows to log unexpected messages
%%-spec unexpected(any(), atom()) -> ok.
unexpected(Msg, State) ->
    error_logger:info_msg("~p received unknown event ~p while in state ~p~n",
			  [self(), Msg, State]).



