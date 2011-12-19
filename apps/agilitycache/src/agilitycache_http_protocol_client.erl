-module(agilitycache_http_protocol_client).

-behaviour(gen_fsm).

-include_lib("kernel/include/inet.hrl").
-include("include/http.hrl").

%% API
-export([start_link/1, start/1]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-export([start_request/1,
	 start_receive_reply/1,
	 get_body/1,
	 send_data/2,
	 stop/1,
	 get_transport_socket/1]).

-export([start_connect/3,
	 idle_wait/3,
	 do_get_body/1,
	 idle_wait/2,
	 do_send_data/2]).


-record(state, {
	  http_req :: #http_req{},
	  http_rep :: #http_rep{},
	  socket :: inet:socket(),
	  transport :: module(),
	  req_empty_lines = 0 :: integer(),
	  max_empty_lines :: integer(),
	  timeout :: timeout(),
	  connection = keepalive :: keepalive | close,
	  buffer = <<>> :: binary()
	 }).

start_request(OwnPid) ->
    gen_fsm:sync_send_event(OwnPid, start_request, infinity).
start_receive_reply(OwnPid) ->
    gen_fsm:sync_send_event(OwnPid, start_receive_reply, infinity).
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
    HttpReq = proplists:get_value(http_req, Opts),
    Transport = proplists:get_value(transport, Opts),
    {ok, start_connect, #state{http_req=HttpReq, timeout=Timeout, max_empty_lines=MaxEmptyLines, transport=Transport}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same
%% name as the current state name StateName is called to handle
%% the event. It is also called if a timeout occurs.
%%
%% @spec state_name(Event, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------

start_connect(start_request, _From, State = #state{http_req = HttpReq, transport = Transport, timeout = Timeout}) ->
    {RawHost, HttpReq0} = agilitycache_http_req:raw_host(HttpReq),
    {Port, HttpReq1} = agilitycache_http_req:port(HttpReq0),
    case Transport:connect(binary_to_list(RawHost), Port, [{buffer, 87380}], Timeout) of
	{ok, Socket} ->
	    ok = Transport:controlling_process(Socket, self()),
	    start_send(State#state{http_req = HttpReq1, socket = Socket});
	{error, Reason} ->
	    {stop, {error, Reason}, State}
    end.

start_send(State = #state{socket=Socket, transport=Transport, http_req=HttpReq}) ->
    Packet = agilitycache_http_req:request_head(HttpReq),
    case Transport:send(Socket, Packet) of
	ok -> 
	    {reply, ok, idle_wait, State};
	{error, Reason} -> 
	    {stop, {error, Reason}, State}
    end.

%%-spec wait_reply(#state{}) -> ok.
wait_reply(State = #state{socket=Socket, transport=Transport,
			  timeout=T, buffer=Buffer}) ->
    case Transport:recv(Socket, 0, T) of
        {ok, Data} -> 
	    start_parse_reply(State#state{buffer= << Buffer/binary, Data/binary >>});
        {error, Reason} ->
	    {stop, {error, Reason}, State}
    end.

%% @private
%%-spec parse_reply(#state{}) -> ok.
%% @todo Use decode_packet options to limit length?
start_parse_reply(State=#state{buffer=Buffer}) ->
    case erlang:decode_packet(http_bin, Buffer, []) of
	{ok, Reply, Rest} -> 
	    parse_reply({Reply, State#state{buffer=Rest}});
	{more, _Length} -> 
	    wait_reply(State);
	{error, Reason} -> 
	    {stop, {error, Reason}, State}
    end. 

%%-spec parse_reply(start_request, _From, {{http_response, http_version(), http_status(), http_string()}, #state{}}) -> ok.
%% @todo We probably want to handle some things differently between versions.
%% @todo We need to cleanup the URI properly.
parse_reply({{http_response, Version, Status, String}, State}) ->
    ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
    start_parse_header(
      State#state{connection=ConnAtom, 
		  http_rep=#http_rep{connection=ConnAtom, status=Status, version=Version, string=String}
		 }      
     );
parse_reply({{http_error, <<"\r\n">>}, State=#state{req_empty_lines=N, max_empty_lines=N}}) ->
    {stop, {http_error, 400}, State};
parse_reply({Data={http_error, <<"\r\n">>}, State=#state{req_empty_lines=N}}) ->
    {next_state, parse_reply, {Data, State#state{req_empty_lines=N + 1}}};
parse_reply({{http_error, _Any}, State}) ->
    {stop, {http_error, 400}, State}.

%%-spec start_parse_header(_Event, #state{}) -> ok.
start_parse_header(State=#state{buffer=Buffer}) ->
    case erlang:decode_packet(httph_bin, Buffer, []) of
	{ok, Header, Rest} -> 
	    parse_header({Header, State#state{buffer=Rest}});
	{more, _Length} -> 
	    wait_header(State);
	{error, _Reason} ->
	    {stop, {http_error, 400}, State}
    end.

%%-spec wait_header(#http_req{}, #state{}) -> ok.
wait_header(State=#state{socket=Socket,
			 transport=Transport, timeout=T, buffer=Buffer}) ->
    case Transport:recv(Socket, 0, T) of
	{ok, Data} -> 
	    start_parse_header(State#state{buffer= << Buffer/binary, Data/binary >>});
	{error, Reason} -> 
	    {stop, {error, Reason}, State}
    end.

%%-spec header({http_header, integer(), http_header(), any(), binary()}
%%	| http_eoh, #http_req{}, #state{}) -> ok.
parse_header({{http_header, _I, 'Connection', _R, Connection}, State=#state{http_rep=Rep}}) ->
    ConnAtom = agilitycache_http_protocol_parser:connection_to_atom(Connection),
    start_parse_header( 
      State#state{
	connection=ConnAtom, 
	http_rep=Rep#http_rep{connection=ConnAtom,
			      headers=[{'Connection', Connection}|Rep#http_rep.headers]
			     }});
parse_header({{http_header, _I, Field, _R, Value}, State=#state{http_rep=Rep}}) ->
    Field2 = agilitycache_http_protocol_parser:format_header(Field),
    start_parse_header(
      State#state{http_rep=Rep#http_rep{headers=[{Field2, Value}|Rep#http_rep.headers]}});
parse_header({http_eoh, State=#state{http_rep=Rep}}) ->
    %%	OK, esperar pedido do cliente.
    {reply, {ok, Rep}, idle_wait, State};
parse_header({{http_error, _Bin}, State}) ->
    {stop, {http_error, 500}, State}.

idle_wait(start_receive_reply, _From, State) ->
    start_parse_reply(State);

idle_wait(get_body, _From, State) ->
    do_get_body(State);
%% different call from someone else. Not supported! Let it die.
idle_wait(Event, _From, State) ->
    unexpected(Event, idle_wait),
    {next_state, idle_wait, State}.

idle_wait({send_data, Data}, State) ->
    do_send_data(Data, State);
idle_wait(Event, State) ->
    unexpected(Event, idle_wait),
    {next_state, idle_wait, State}.

%% Empty buffer
do_get_body(State=#state{
	      socket=Socket, transport=Transport, timeout=T, buffer = <<>>}) ->
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
do_get_body(State=#state{buffer = Buffer}) ->
    {reply, {ok, Buffer}, idle_wait, State#state{buffer = <<>>}}.

do_send_data(Data, State=#state{
		     socket=Socket, transport=Transport}) ->
    case Transport:send(Socket, Data) of
	ok -> 
	    {next_state, idle_wait, State};
	{error, closed} -> 
	    %% @todo Eu devia alertar sobre isso, não?
	    {stop, normal, State};
	{error, Reason} -> 
	    {stop, {error, Reason}, State}
    end.

%%-spec do_terminate(#state{}) -> ok.
do_terminate(#state{socket=Socket, transport=Transport}) ->
  %%unexpected("Olha eu fechanado...", do_terminate),
    Transport:close(Socket),
    ok.    

%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/[2,3], the instance of this function with
%% the same name as the current state name StateName is called to
%% handle the event.
%%
%% @spec state_name(Event, From, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------
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
terminate(_Reason, _StateName, StateData) ->
  do_terminate(StateData),
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
