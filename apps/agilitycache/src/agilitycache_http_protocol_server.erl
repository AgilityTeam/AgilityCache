-module(agilitycache_http_protocol_server).

-behaviour(gen_fsm).

-include("include/http.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/1, start/1]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-export([receive_request/1,
	 get_body/1,
	 send_data/2,
	 stop/1,
	 get_transport_socket/1]).

-export([start_receive_request/3,
	 idle_wait/3,
	 do_get_body/1,
	 idle_wait/2,
	 do_send_data/1]).		 

-define(SERVER, ?MODULE).

-record(state, {
	  http_req :: #http_req{},
	  socket :: inet:socket(),
	  transport :: module(),
	  req_empty_lines = 0 :: integer(),
	  max_empty_lines :: integer(),
	  timeout :: timeout(),
	  connection = keepalive :: keepalive | close,
	  buffer = <<>> :: binary(),
	  from :: pid()
	 }).

receive_request(OwnPid) ->
    gen_fsm:sync_send_event(OwnPid, receive_request, infinity).
get_body(OwnPid) ->
    gen_fsm:sync_send_event(OwnPid, get_body, infinity).
send_data(OwnPid, Data) ->
    gen_fsm:send_event(OwnPid, {send_data, Data}).	 
stop(OwnPid) ->
    gen_fsm:send_all_state_event(OwnPid, stop).	   
get_transport_socket(OwnPid) ->
    gen_fsm:sync_send_all_state_event(OwnPid, get_transport_socket).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
-spec start_link(any()) -> {ok, pid()}.
start_link(Opts) ->
    gen_fsm:start_link(?MODULE, Opts, []).

-spec start(any()) -> {ok, pid()}.
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
-spec init(any()) -> {ok, atom(), #state{}}.
init(Opts) ->
    MaxEmptyLines = proplists:get_value(max_empty_lines, Opts, 5),
    Timeout = proplists:get_value(timeout, Opts, 5000),
    Transport = proplists:get_value(transport, Opts),
    Socket = proplists:get_value(socket, Opts),
    {ok, start_receive_request, #state{timeout=Timeout, 
				       max_empty_lines=MaxEmptyLines, transport=Transport, socket=Socket }}.

start_receive_request(receive_request, From, State=#state{socket=Socket, transport=Transport}) ->
	Transport:controlling_process(Socket, self()),
    wait_request(State#state{from=From}).

%%-spec wait_request(#state{}) -> ok.
wait_request(State=#state{socket=Socket, transport=Transport,
			  timeout=T, buffer=Buffer}) ->
    case Transport:recv(Socket, 0, T) of
	{ok, Data} -> 
	    start_parse_request(State#state{buffer= << Buffer/binary, Data/binary >>});
	{error, timeout} -> 
	    {stop, {http_error, 408}, State};
	{error, closed} -> 
	    {stop, closed, State}
    end.

%%-spec start_parse_request(#state{}) -> ok.
%% @todo Use decode_packet options to limit length?
start_parse_request(State=#state{buffer=Buffer}) ->
    case erlang:decode_packet(http_bin, Buffer, []) of
	{ok, Request, Rest} -> 
	    parse_request(Request, State#state{buffer=Rest});
	{more, _Length} -> 
	    wait_request(State);
	{error, _Reason} -> 
	    {stop, {http_error, 400}, State}
    end.

%%-spec parse_request({http_request, http_method(), http_uri(), http_version()}, #state{}) -> ok.
%% @todo We need to cleanup the URI properly.
parse_request({http_request, Method, {abs_path, AbsPath}, Version}, State) ->
    {Path, RawPath, Qs} = agilitycache_dispatcher:split_path(AbsPath),
    ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
    start_parse_header(State#state{connection=ConnAtom, http_req=#http_req{
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
		     State#state{connection=ConnAtom, http_req=#http_req{
							connection=ConnAtom, method=Method, version=Version,
							path=Path, raw_path=RawPath, raw_qs=Qs,
							host=Host, raw_host=RawHost3, port=DefaultPort,
							headers=[{'Host', RawHost3}]}};
		 {_, {Host, RawHost3, DefaultPort}} ->
		     State#state{connection=ConnAtom, http_req=#http_req{
							connection=ConnAtom, method=Method, version=Version,
							path=Path, raw_path=RawPath, raw_qs=Qs,
							host=Host, raw_host=RawHost3, port=DefaultPort,
							headers=[{'Host', RawHost3}]}};
		 {undefined, {Host, RawHost3, undefined}} ->
		     State#state{connection=ConnAtom, http_req=#http_req{
							connection=ConnAtom, method=Method, version=Version,
							path=Path, raw_path=RawPath, raw_qs=Qs,
							host=Host, raw_host=RawHost3, port=DefaultPort,
							headers=[{'Host', RawHost3}]}};
		 {undefined, {Host, RawHost3, Port}} ->
			 BinaryPort = list_to_binary(integer_to_list(Port)),
		     State#state{connection=ConnAtom, http_req=#http_req{
							connection=ConnAtom, method=Method, version=Version,
							path=Path, raw_path=RawPath, raw_qs=Qs,
							host=Host, raw_host=RawHost3, port=Port,
							headers=[{'Host', << RawHost3/binary, ":", BinaryPort/binary>>}]}};
		 {Port, {Host, RawHost3, _}} ->
			 BinaryPort = list_to_binary(integer_to_list(Port)),
		     State#state{connection=ConnAtom, http_req=#http_req{
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
			start_parse_header(State2)
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

%%-spec start_parse_header(#http_req{}, #state{}) -> ok.
start_parse_header(State=#state{buffer=Buffer}) ->
    case erlang:decode_packet(httph_bin, Buffer, []) of
	{ok, Header, Rest} -> 
	    parse_header(Header, State#state{buffer=Rest});
	{more, _Length} -> 
	    wait_header(State);
	{error, _Reason} -> 
	    {stop, {http_error, 400}, State}
    end.

%%-spec wait_header(#http_req{}, #state{}) -> ok.
wait_header(State=#state{socket=Socket, transport=Transport, timeout=T, buffer=Buffer}) ->
    case Transport:recv(Socket, 0, T) of
	{ok, Data} -> 
	    start_parse_header(State#state{buffer= << Buffer/binary, Data/binary >>});
	{error, timeout} -> 
	    {stop, {http_error, 408}, State};
	{error, closed} -> 
	    {stop, {http_error, 500}, State}
    end.

%% -spec header({http_header, integer(), http_header(), any(), binary()} | http_eoh, #http_req{}, #state{}) -> ok.
parse_header({http_header, _I, 'Host', _R, RawHost}, 
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
			start_parse_header(State2)
	 end;
%% Ignore Host headers if we already have it.
parse_header({http_header, _I, 'Host', _R, _V}, State) ->
    start_parse_header(State);
parse_header({http_header, _I, 'Connection', _R, Connection}, State = #state{http_req=Req}) ->
    ConnAtom = agilitycache_http_protocol_parser:connection_to_atom(Connection),
    start_parse_header(State#state{connection=ConnAtom, http_req=Req#http_req{connection=ConnAtom,
									      headers=[{'Connection', Connection}|Req#http_req.headers]}});
parse_header({http_header, _I, Field, _R, Value}, State = #state{http_req=Req}) ->
    Field2 = agilitycache_http_protocol_parser:format_header(Field),
    start_parse_header(State#state{http_req=Req#http_req{headers=[{Field2, Value}|Req#http_req.headers]}});
%% The Host header is required in HTTP/1.1.
parse_header(http_eoh, State=#state{http_req=Req}) when Req#http_req.version=:= {1, 1} andalso Req#http_req.host=:=undefined ->
    {stop, {http_error, 400}, State};
%% It is however optional in HTTP/1.0.
%% @todo Devia ser um erro, host undefined o.O
parse_header(http_eoh, State=#state{transport=Transport, http_req=Req=#http_req{version={1, 0}, host=undefined}}) ->
    Port = agilitycache_http_protocol_parser:default_port(Transport:name()),
    %% Ok, terminar aqui, e esperar envio!
    {reply, {ok, Req#http_req{host=[], raw_host= <<>>, port=Port}},
     idle_wait, 
     State#state{http_req=Req#http_req{host=[], raw_host= <<>>, port=Port}}};
parse_header(http_eoh, State=#state{http_req=Req}) ->
    %% Ok, terminar aqui, e esperar envio!
    {reply, {ok, Req}, idle_wait, State};
parse_header({http_error, _Bin}, State) ->
    {stop, {http_error, 500}, State}.

idle_wait(get_body, From, State) ->
    do_get_body(State#state{from=From});
%% different call from someone else. Not supported! Let it die.
idle_wait(Event, _From, State) ->
    unexpected(Event, idle_wait),
    {next_state, idle_wait, State}.

idle_wait({send_data, Data}, State) ->
    do_send_data(State#state{buffer=Data});
idle_wait(Event, State) ->
    unexpected(Event, idle_wait),
    {next_state, idle_wait, State}.

%% Empty buffer
do_get_body(State=#state{
	      socket=Socket, transport=Transport, timeout=T, buffer= <<>>})->
    case Transport:recv(Socket, 0, T) of
	{ok, Data} ->
	    {reply, {ok, Data}, idle_wait, State};
	{error, closed} ->
	    {reply, closed, idle_wait, State};
	{error, timeout} ->
	    {reply, timeout, idle_wait, State};
	{error, Reason} ->
	    {stop, {error, Reason}, State}
    end;
%% Non empty buffer
do_get_body(State=#state{buffer=Buffer})->
    {reply, {ok, Buffer}, idle_wait, State#state{buffer = <<>>}}.

do_send_data(State=#state{
	       socket=Socket, transport=Transport, buffer=Data}) ->
    case Transport:send(Socket, Data) of
	ok -> 
	    {next_state, idle_wait, State#state{buffer= <<>>}};
	{error, closed} -> 
		%% @todo Eu devia alertar sobre isso, não?
		{stop, normal, State};
	{error, Reason} -> 
	    {stop, {error, Reason}, State}
    end.

%%-spec do_terminate(#state{}) -> ok.
do_terminate(#state{socket=Socket, transport=Transport}) ->
    Transport:close(Socket),
    ok.    


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
    do_terminate(StateData),
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
handle_sync_event(get_transport_socket, _From, StateName, State = #state{socket=Socket, transport=Transport}) ->
    Reply = {Socket, Transport},
    {reply, Reply, StateName, State};
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
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

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
terminate(_Reason, _StateName, _State) ->
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
