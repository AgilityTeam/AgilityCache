%% This file is part of AgilityCache, a web caching proxy.
%%
%% Copyright (C) 2011, 2012 Joaquim Pedro França Simão
%%
%% AgilityCache is free software: you can redistribute it and/or modify
%% it under the terms of the GNU Affero General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% AgilityCache is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU Affero General Public License for more details.
%%
%% You should have received a copy of the GNU Affero General Public License
%% along with this program.  If not, see <http://www.gnu.org/licenses/>.

-module(agilitycache_http_session).

-behaviour(gen_fsm).

%% API
-export([start_link/4, sub_start/4]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).
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
-export([protocol_loop/1]).

-include("http.hrl").

-record(state, {
          http_server :: pid(),
          http_client :: pid(),
          transport :: module(),
          max_empty_lines = 5 :: integer(),
          timeout = 5000 :: timeout(),
          keepalive = both :: both | req | disabled,
          keepalive_timeout = 120000 :: timeout(),
          start_time = 0 :: integer(),
          restant = 0 :: integer()
         }).

start_link(ListenerPid, Socket, Transport, Opts) ->
    Pid = spawn_link(?MODULE, sub_start, [ListenerPid, Socket, Transport, Opts]),
    {ok, Pid}.

sub_start(ListenerPid, Socket, Transport, Opts) ->
    {ok, SessionPid} = gen_fsm:start_link(?MODULE, {Socket, Transport, Opts}, []),
    Transport:controlling_process(Socket, SessionPid),
    ranch:accept_ack(ListenerPid),
    protocol_loop(SessionPid),
    ok.

protocol_loop(Pid) ->
    case gen_fsm:sync_send_event(Pid, simple, infinity) of
        ok ->
            ok;
        continue ->
            protocol_loop(Pid)
    end.

init({ServerSocket, Transport, Opts}) ->

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
                                     {buffer, BufferSize}
                                    ]),

    {ok, HttpServer} = agilitycache_http_server:start_link(Transport, ServerSocket, Timeout, MaxEmptyLines),
    Transport:controlling_process(ServerSocket, HttpServer),

    KeepAliveOpts = agilitycache_utils:get_app_env(keepalive,[]),
    KeepAlive = proplists:get_value(type, KeepAliveOpts, both),
    KeepAliveDefault = proplists:get_value(max_timeout, KeepAliveOpts, 120000),

    {ok, start_handle_request,
     #state{http_server=HttpServer,
            timeout=Timeout,
            max_empty_lines=MaxEmptyLines,
            transport=Transport,
            keepalive = KeepAlive,
            keepalive_timeout = KeepAliveDefault,
            start_time = StartTime}}.

%% Events

start_handle_request(_Event, _From,
                     #state{http_server=HttpServer} = State) ->
    ok = agilitycache_http_server:read_request(HttpServer),
    {reply, continue, read_reply,State}.

read_reply(_Event, _From,
           #state{http_server=HttpServer, transport=Transport,
                  timeout=Timeout,
                  max_empty_lines=MaxEmptyLines} = State) ->
    HttpReq = agilitycache_http_server:get_http_req(HttpServer),
    {ok, HttpClient} = agilitycache_http_client:start_link(Transport, Timeout, MaxEmptyLines),

    HttpReq0 = agilitycache_http_client:start_request(HttpClient, HttpReq),
    ok = agilitycache_http_server:set_http_req(HttpServer, HttpReq0),
    Method = agilitycache_http_protocol_parser:method_to_binary(HttpReq0#http_req.method),
    case Method of
        <<"POST">> ->
            {reply, continue, start_send_post,
             State#state{http_client=HttpClient}};
        _ ->
            {reply, continue, start_receive_reply,
             State#state{http_client=HttpClient}}
    end.
start_send_post(_Event, _From,
                #state{http_server=HttpServer} = State) ->
    HttpReq = agilitycache_http_server:get_http_req(HttpServer),
    {Length, HttpReq2} =
        agilitycache_http_req:content_length(HttpReq),
    ok = agilitycache_http_server:set_http_req(HttpServer, HttpReq2),
    lager:debug("Length: ~p", [Length]),
    case Length of
        0 ->
            {reply, continue, start_receive_reply, State#state{restant=0}};
        _ when is_integer(Length) ->
            {reply, continue, send_post,
             State#state{restant=Length}}
    end.
send_post(_Event, _From,
          #state{http_client=HttpClient,
                 http_server=HttpServer,
                 restant=Length} = State) ->
    Data = agilitycache_http_server:get_body(HttpServer),
    DataSize = iolist_size(Data),
    Restant = Length - DataSize,
    ok = agilitycache_http_client:send_data(HttpClient, Data),
    case Restant of
        0 ->
            {reply, continue, start_receive_reply, State};
        _ when Restant > 0 ->
            {reply, continue, send_post, State#state{restant=Restant}}
    end.
start_receive_reply(_Event, _From,
                    #state{http_client = HttpClient} = State) ->
    ok = agilitycache_http_client:start_receive_reply(HttpClient),
    {reply, continue, start_send_reply, State}.
start_send_reply(_Event, _From,
                 #state{http_server=HttpServer,
                        http_client=HttpClient} = State) ->
    HttpRep = agilitycache_http_client:get_http_rep(HttpClient),
    {Status, Rep2} = agilitycache_http_rep:status(HttpRep),
    {Headers, Rep3} = agilitycache_http_rep:headers(Rep2),
    {Length, Rep4} = agilitycache_http_rep:content_length(Rep3),
    Req = agilitycache_http_server:get_http_req(HttpServer),
    {ok, Req2, HttpServer} =
        agilitycache_http_req:start_reply(HttpServer,
                                          Status, Headers,
                                          Length, Req),
    ok = agilitycache_http_client:set_http_rep(HttpClient, Rep4),
    ok = agilitycache_http_server:set_http_req(HttpServer, Req2),
    case Status of
        101 ->
            {reply, continue, do_basic_loop, State};
        _ ->
            {reply, continue, send_reply, State#state{restant=Length}}
    end.
do_basic_loop(_Event, _From,
              #state{http_server=HttpServer,
                     http_client=HttpClient,
                     transport=Transport} = State) ->
    ServerSocket = agilitycache_http_server:get_socket(HttpServer, self()),
    ClientSocket = agilitycache_http_client:get_socket(HttpClient, self()),
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
            HttpRep = agilitycache_http_client:get_http_rep(HttpClient),
            ok = agilitycache_http_client:set_http_rep(HttpClient, HttpRep#http_rep{connection=close}),
            lager:debug("stopping"),
            {stop, normal, ok, State};
        {tcp_closed, ServerSocket} ->
            HttpReq = agilitycache_http_server:get_http_req(HttpServer),
            ok = agilitycache_http_server:set_http_req(HttpServer, HttpReq#http_req{connection=close}),
            lager:debug("stopping"),
            {stop, normal, ok, State}
    end.
send_reply(_Event, _From,
           #state{http_server=HttpServer,
                  http_client=HttpClient,
                  restant=Remaining} = State) ->
    Data = agilitycache_http_client:get_body(HttpClient),

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
    ok = agilitycache_http_server:send_data(HttpServer, Data),
    case Ended of
        true ->
            lager:debug("stopping"),
            {reply, continue, begin_stop, State};
        false ->
            {reply, continue, send_reply, State#state{restant=NewRemaining}}
    end.
begin_stop(_Event, _From, #state{keepalive=disabled} = State) ->
    {stop, normal, ok, State};
begin_stop(_Event, _From, #state{keepalive=KeepAliveType,
                                 http_server=HttpServer,
                                 http_client=HttpClient,
                                 start_time=StartTime} = State) ->
    HttpReq = agilitycache_http_server:get_http_req(HttpServer),
    HttpRep = agilitycache_http_client:get_http_rep(HttpClient),
    case {KeepAliveType, HttpReq#http_req.connection,
          HttpRep#http_rep.connection} of
        {both, keepalive, keepalive} ->
            agilitycache_http_server:end_request(HttpServer),
            agilitycache_http_client:end_reply(HttpClient),

            EndTime = os:timestamp(),
            folsom_metrics:notify(
              {total_proxy_time,
               timer:now_diff(EndTime, StartTime)}),
            {reply, continue, start_handle_both_keepalive_request, State};
        {_, keepalive, close} ->
            agilitycache_http_server:end_request(HttpServer),
            agilitycache_http_client:end_reply(HttpClient),
            agilitycache_http_client:stop(HttpClient),
            agilitycache_http_server:set_http_req(HttpServer, #http_req{}), %% Vazio
            EndTime = os:timestamp(),
            folsom_metrics:notify(
              {total_proxy_time,
               timer:now_diff(EndTime, StartTime)}),
            {reply, continue,
             start_handle_req_keepalive_request, State};
        _ ->
            {stop, normal, ok, State}
    end.

start_handle_req_keepalive_request(_Event, _From, #state{
                                             http_server=HttpServer,
                                             keepalive_timeout =
                                                 KeepAliveTimeout} =
                                       State) ->
    ok = agilitycache_http_server:read_keepalive_request(HttpServer, KeepAliveTimeout),
    {reply, continue, read_reply, State}.

start_handle_both_keepalive_request(_Event, _From,
                                    #state{http_server=HttpServer,
                                           http_client=HttpClient,
                                           keepalive_timeout=KeepAliveTimeout} = State) ->
    try agilitycache_http_server:read_keepalive_request(HttpServer, KeepAliveTimeout) of
        ok ->
            %% Check if is same host:port
            OldDomainPort = agilitycache_http_client:get_host_port(HttpClient),

            HttpReq = agilitycache_http_server:get_http_req(HttpServer),
            NewHostPort = {HttpReq#http_req.uri#http_uri.domain, HttpReq#http_req.uri#http_uri.port},

            case NewHostPort of
                OldDomainPort ->
                    lager:debug("Same host keepalive, right! ~p", [NewHostPort]),
                    {reply, continue, read_both_keepalive_reply, State};
                _ ->
                    lager:debug("Different host keepalive :( ~p <-> ~p", [OldDomainPort, NewHostPort]),
                    agilitycache_http_client:end_reply(HttpClient),
                    agilitycache_http_client:stop(HttpClient),
                    {reply, continue, read_reply, State}
            end
    catch
        error:closed ->
            {reply, continue, read_reply, State}
    end.

read_both_keepalive_reply(_Event, _From,
                          #state{http_server=HttpServer,
                                 http_client=HttpClient} = State) ->
    HttpReq = agilitycache_http_server:get_http_req(HttpServer),
    HttpReq0 = agilitycache_http_client:start_keepalive_request(HttpClient, HttpReq),
    agilitycache_http_server:set_http_req(HttpServer, HttpReq0),
    Method =
        agilitycache_http_protocol_parser:method_to_binary(
          HttpReq0#http_req.method),
    case Method of
        <<"POST">> ->
            {reply, continue, start_send_post, State};
        _ ->
            {reply, continue, start_receive_reply, State}
    end.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(Reason, _StateName, #state{start_time=StartTime,
                                     http_server=HttpServer,
                                     http_client=HttpClient}) ->
    lager:debug("terminate Reason: ~p", [Reason]),
    EndTime = os:timestamp(),
    folsom_metrics:notify({total_proxy_time,
                           timer:now_diff(EndTime, StartTime)}),
    agilitycache_http_server:end_request(HttpServer),
    agilitycache_http_client:end_reply(HttpClient),
    agilitycache_http_server:stop(HttpServer),
    agilitycache_http_client:stop(HttpClient),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.
