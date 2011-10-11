-module(agilitycache_http_protocol_server).

-behaviour(gen_fsm).

-include("include/http.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/0]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

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
    error_logger:info_msg("Opts: ~p~n", [Opts]),
    MaxEmptyLines = proplists:get_value(max_empty_lines, Opts, 5),
    Timeout = proplists:get_value(timeout, Opts, 5000),
    Transport = proplists:get_value(transport, Opts),
    Socket = proplists:get_value(socket, Opts),
    {ok, start_receive_request, #state{http_req=HttpReq, timeout=Timeout, 
				       max_empty_lines=MaxEmptyLines, transport=Transport, socket=Socket }}.

start_receive_request(receive_request, From, State) ->
    wait_request(State#state{from=From}).

%%-spec wait_request(#state{}) -> ok.
wait_request(State=#state{socket=Socket, transport=Transport,
			  timeout=T, buffer=Buffer}) ->
    case Transport:recv(Socket, 0, T) of
	{ok, Data} -> 
	    start_parse_request(State#state{buffer= << Buffer/binary, Data/binary >>});
	{error, timeout} -> 
	    {stop, 408, State};
	{error, closed} -> 
	    {stop, closed, State};
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
	    {stop, 400, State};
	end.

%%-spec parse_request({http_request, http_method(), http_uri(), http_version()}, #state{}) -> ok.
%% @todo We probably want to handle some things differently between versions.
parse_request({http_request, _Method, _URI, Version}, State)
  when Version =/= {1, 0}, Version =/= {1, 1} ->
    {stop, 505, State};
%% @todo We need to cleanup the URI properly.
parse_request({http_request, Method, {abs_path, AbsPath}, Version},
	      State=#state{socket=Socket, transport=Transport}) ->
    {Path, RawPath, Qs} = agilitycache_dispatcher:split_path(AbsPath),
    ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
    start_parse_header(State#state{connection=ConnAtom, http_req=#http_req{socket=Socket, transport=Transport,
									   connection=ConnAtom, method=Method, version=Version,
									   path=Path, raw_path=RawPath, raw_qs=Qs}});
parse_request({http_request, Method, {absoluteURI, http, RawHost, undefined, AbsPath}, Version},
	      State=#state{socket=Socket, transport=Transport}) ->
    {Path, RawPath, Qs} = agilitycache_dispatcher:split_path(AbsPath),
    ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
    RawHost2 = agilitycache_http_protocol_parser:binary_to_lower(RawHost),
    case catch agilitycache_dispatcher:split_host(RawHost2) of 
	{Host, RawHost3, undefined} ->
	    Port = agilitycache_http_protocol_parser:default_port(Transport:name()),
	    start_parse_header(State#state{connection=ConnAtom, http_req=#http_req{socket=Socket, transport=Transport,
										   connection=ConnAtom, method=Method, version=Version,
										   path=Path, raw_path=RawPath, raw_qs=Qs,
										   host=Host, raw_host=RawHost3, port=Port}});

	{Host, RawHost3, Port} ->
	    start_parse_header(State#state{connection=ConnAtom, http_req=#http_req{socket=Socket, transport=Transport,
										   connection=ConnAtom, method=Method, version=Version,
										   path=Path, raw_path=RawPath, raw_qs=Qs,
										   host=Host, raw_host=RawHost3, port=Port}});
	_ ->
	    {stop, 400, State}
    end;

parse_request({http_request, Method, {absoluteURI, http, RawHost, Port, AbsPath}, Version},
	      State=#state{socket=Socket, transport=Transport}) ->
    {Path, RawPath, Qs} = agilitycache_dispatcher:split_path(AbsPath),
    ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
    RawHost2 = agilitycache_http_protocol_parser:binary_to_lower(RawHost),
    case catch agilitycache_dispatcher:split_host(RawHost2) of
	{Host, RawHost3, undefined} ->
	    start_parse_header(State#state{connection=ConnAtom, http_req=#http_req{socket=Socket, transport=Transport,
										   connection=ConnAtom, method=Method, version=Version,
										   path=Path, raw_path=RawPath, raw_qs=Qs,
										   host=Host, raw_host=RawHost3, port=Port}});

	{Host, RawHost3, Port2} ->
	    start_parse_header(State#state{connection=ConnAtom, http_req=#http_req{socket=Socket, transport=Transport,
										   connection=ConnAtom, method=Method, version=Version,
										   path=Path, raw_path=RawPath, raw_qs=Qs,
										   host=Host, raw_host=RawHost3, port=Port2}});
	_ ->
	    {stop, 400, State}
    end;

parse_request({http_request, Method, '*', Version},
	      State=#state{socket=Socket, transport=Transport}) ->
    ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
    start_parse_header(State#state{connection=ConnAtom, http_req=#http_req{socket=Socket, transport=Transport,
									   connection=ConnAtom, method=Method, version=Version,
									   path='*', raw_path= <<"*">>, raw_qs= <<>>}});
parse_request({http_request, _Method, _URI, _Version}, State) ->
    {stop, 501, State};
request({http_error, <<"\r\n">>},
	State=#state{req_empty_lines=N, max_empty_lines=N}) ->
    {stop, 400, State};
parse_request({http_error, <<"\r\n">>}, State=#state{req_empty_lines=N}) ->
    parse_request(State#state{req_empty_lines=N + 1});
parse_request({http_error, _Any}, State) ->
    {stop, 400, State}.

%%-spec start_parse_header(#http_req{}, #state{}) -> ok.
start_parse_header(State=#state{buffer=Buffer}) ->
    case erlang:decode_packet(httph_bin, Buffer, []) of
	{ok, Header, Rest} -> 
	    parse_header(Header, State#state{buffer=Rest});
	{more, _Length} -> 
	    wait_header(Req, State);
	{error, _Reason} -> 
	    {stop, 400, State};
	end.

%%-spec wait_header(#http_req{}, #state{}) -> ok.
wait_header(State=#state{socket=Socket, transport=Transport, timeout=T, buffer=Buffer}) ->
    case Transport:recv(Socket, 0, T) of
	{ok, Data} -> 
	    start_parse_header(State#state{buffer= << Buffer/binary, Data/binary >>});
	{error, timeout} -> 
	    {stop, 408, State};
	{error, closed} -> 
	    {stop, 500, State};
	end.

%% -spec header({http_header, integer(), http_header(), any(), binary()} | http_eoh, #http_req{}, #state{}) -> ok.
parse_header({http_header, _I, 'Host', _R, RawHost}, 
	     State = #state{http_req=Req#http_req{transport=Transport, host=undefined}}) ->
    RawHost2 = agilitycache_http_protocol_parser:binary_to_lower(RawHost),
    case catch agilitycache_dispatcher:split_host(RawHost2) of
	{Host, RawHost3, undefined} ->
	    Port = agilitycache_http_protocol_parser:default_port(Transport:name()),
	    parse_header(State#state{http_req=Req#http_req{
					   host=Host, raw_host=RawHost3, port=Port,
					   headers=[{'Host', RawHost3}|Req#http_req.headers]}});
	{Host, RawHost3, Port} ->
	    parse_header(State#state{http_req=Req#http_req{
					   host=Host, raw_host=RawHost3, port=Port,
					   headers=[{'Host', RawHost3}|Req#http_req.headers]}} );
	{'EXIT', _Reason} ->
	    error_terminate(400, State)
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
parse_header(http_eoh, #http_req{version={1, 1}, host=undefined}, State) ->
    {stop, 400, State};
%% It is however optional in HTTP/1.0.
parse_header(http_eoh, Req=#http_req{version={1, 0}, transport=Transport,
				     host=undefined}, State=#state{buffer=Buffer}) ->
    Port = agilitycache_http_protocol_parser:default_port(Transport:name()),
    %% Ok, terminar aqui, e esperar envio!
    dispatch(fun handler_init/2, Req#http_req{host=[], raw_host= <<>>,
					      port=Port, buffer=Buffer}, State#state{buffer= <<>>});
parse_header(http_eoh, Req, State=#state{buffer=Buffer}) ->
	%% Ok, terminar aqui, e esperar envio!
    dispatch(fun handler_init/2, Req#http_req{buffer=Buffer}, State#state{buffer= <<>>});
parse_header({http_error, _Bin}, _Req, State) ->
    {stop, 500, State}.

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

