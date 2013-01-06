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

-module(agilitycache_http_server).

-behaviour(gen_server).
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export([start_link/4]).

-export([read_request/1, read_keepalive_request/2, get_body/1, send_data/2, get_http_req/1, set_http_req/2, end_request/1, stop/1]).
-export([get_socket/2, set_socket/2]).

-include("http.hrl").

-record(state, {
          http_req :: #http_req{},
          server_socket :: inet:socket(),
          transport :: module(),
          req_empty_lines = 0 :: integer(),
          max_empty_lines :: integer(),
          timeout = 5000 :: timeout(),
          server_buffer = <<>> :: binary()
         }).

start_link(Transport, ServerSocket, Timeout, MaxEmptyLines) ->
    gen_server:start_link(?MODULE, [Transport, ServerSocket, Timeout, MaxEmptyLines], []).

init([Transport, ServerSocket, Timeout, MaxEmptyLines]) ->
    {ok, #state{timeout=Timeout, max_empty_lines=MaxEmptyLines, transport=Transport,
                server_socket=ServerSocket}}.

%% Public API
%% ===============================================================

read_request(Pid) ->
    gen_server:call(Pid, read_request, infinity).

read_keepalive_request(Pid, Timeout) ->
    gen_server:call(Pid, {read_keepalive_request, Timeout}, infinity).

get_body(Pid) ->
    gen_server:call(Pid, get_body, infinity).

send_data(Pid, Data) ->
    gen_server:call(Pid, {send_data, Data}, infinity).

get_http_req(Pid) ->
    gen_server:call(Pid, get_http_req, infinity).

set_http_req(Pid, Req) ->
    gen_server:call(Pid, {set_http_req, Req}, infinity).

end_request(Pid) ->
    gen_server:call(Pid, end_request, infinity).

stop(Pid) ->
    gen_server:call(Pid, stop, infinity).

get_socket(Pid, OuterPid) ->
    gen_server:call(Pid, {get_socket, OuterPid}, infinity).

set_socket(Pid, Socket) ->
    gen_server:call(Pid, {set_socket, Socket}, infinity).

%% ===============================================================


handle_call(get_http_req, _From, State) ->
    handle_get_http_req(State);
handle_call({set_http_req, HttpReq}, _From, State) ->
    handle_set_http_req(HttpReq, State);
handle_call(read_request, _From, State) ->
    handle_read_request(State);
handle_call({read_keepalive_request, KeepAliveTimeout}, _From, State) ->
    handle_read_keepalive_request(KeepAliveTimeout, State);
handle_call(get_body, _From, State) ->
    handle_get_body(State);
handle_call({send_data, Data}, _From, State) ->
    handle_send_data(Data, State);
handle_call(end_request, _From, State) ->
    handle_end_request(State);
handle_call(stop, _From, State) ->
    handle_stop(State);
handle_call({get_socket, OtherPid}, _From, State) ->
    handle_get_socket(OtherPid, State);
handle_call({set_socket, Socket}, _From, State) ->
    handle_set_socket(Socket, State);
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, State) ->
    lager:debug("terminate Reason: ~p", [Reason]),
    close_socket(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ==============================================

handle_get_http_req(#state{http_req = HttpReq} = State) ->
    {reply, HttpReq, State}.

handle_set_http_req(HttpReq, State) ->
    {reply, ok, State#state{http_req = HttpReq}}.

handle_get_socket(OtherPid, #state{server_socket = Socket, transport = Transport} = State) ->
    Transport:controlling_process(Socket, OtherPid),
    {reply, Socket, State}.

handle_set_socket(Socket, State) ->
    {reply, ok, State#state{server_socket=Socket}}.

handle_read_request(State) ->
    wait_request(State).

handle_read_keepalive_request(KeepAliveTimeout, State) ->
    wait_keepalive_request(KeepAliveTimeout, State).

%% Empty buffer
handle_get_body(State=#state{
                  server_socket=Socket, transport=Transport, timeout=T, server_buffer= <<>>})->
    {ok, Data} = Transport:recv(Socket, 0, T),
    {reply, Data, State};
%% Non empty buffer
handle_get_body(State=#state{server_buffer=Buffer})->
    {reply, Buffer, State#state{server_buffer = <<>>}}.

handle_send_data(Data, State = #state { transport = Transport, server_socket = Socket } ) ->
    ok = Transport:send(Socket, Data),
    {reply, ok, State}.

handle_end_request(State) ->
    {reply, ok, State#state{http_req = #http_req{}, server_buffer = <<>>, req_empty_lines = 0}}.

handle_stop(State) ->
    {stop, normal, ok, State#state{server_socket=undefined}}.

close_socket(#state{server_socket=undefined}) ->
    ok;
close_socket(#state{transport=Transport, server_socket=Socket}) ->
    Transport:close(Socket).

wait_request(State=#state{timeout=T}) ->
    wait_request(T, State).
wait_keepalive_request(KeepAliveTimeout, State) ->
    wait_request(KeepAliveTimeout, State).

wait_request(Timeout, State=#state{server_socket=Socket, transport=Transport, server_buffer=Buffer}) ->
    {ok, Data} = Transport:recv(Socket, 0, Timeout),
    start_parse_request(State#state{server_buffer = << Buffer/binary, Data/binary>>}).

%% @todo Use decode_packet options to limit length?
start_parse_request(State=#state{server_buffer=Buffer}) ->
    case erlang:decode_packet(http_bin, Buffer, []) of
        {ok, Request, Rest} ->
            lager:debug("parse_request: ~p", [Request]),
            lager:debug("Rest: ~p", [Rest]),
            parse_request(Request, State#state{server_buffer=Rest});
        {more, _Length} ->
            wait_request(State)
    end.

parse_request({http_request, Method, {abs_path, AbsPath}, Version}, State = #state{server_socket = Socket, transport=Transport}) ->
    {RawPath, Qs} = httpd_util:split_path(binary_to_list(AbsPath)),
    ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
    {ok, Peer} = Transport:peername(Socket),
    start_parse_request_header(State#state{http_req=#http_req{
                                             connection=ConnAtom, method=Method, version=Version,
                                             peer = Peer,
                                             uri = #http_uri{ path=RawPath, query_string = Qs} }});
parse_request({http_request, Method, {absoluteURI, http, RawHost, RawPort, AbsPath}, Version},
              State=#state{transport=Transport}) ->
    ConnAtom = agilitycache_http_protocol_parser:version_to_connection(Version),
    DefaultPort = agilitycache_http_protocol_parser:default_port(Transport:name()),

    TmpPort = case RawPort of
                  undefined ->
                      DefaultPort;
                  _ ->
                      RawPort
              end,
    {ok,
     {http, _UserInfo, THost, Port, TPath, TQuery}} = http_uri:parse("http://"
                                                                  ++ binary_to_list(RawHost)
                                                                  ++ ":" ++ integer_to_list(TmpPort)
                                                                  ++ binary_to_list(AbsPath)),
    Host = list_to_binary(THost),
    Path = list_to_binary(TPath),
    Query = list_to_binary(TQuery),

    HttpReq = #http_req{connection=ConnAtom, method=Method, version=Version,
                        uri = #http_uri{ domain=Host, port=Port, path=Path, query_string = Query}},
    State2 = case Port of
                 DefaultPort ->
                     State#state{http_req=HttpReq#http_req{headers=[{'Host', Host}]}};
                 _ ->
                     BinaryPort = list_to_binary(integer_to_list(Port)),
                     State#state{http_req=HttpReq#http_req{headers=[{'Host', << Host/binary, ":", BinaryPort/binary>>}]}}
             end,
    start_parse_request_header(State2);

parse_request({http_error, <<"\r\n">>},
              State=#state{req_empty_lines=N, max_empty_lines=N}) ->
    {stop, {http_error, 400}, {error, {http_error, 400}}, State};
parse_request({http_error, <<"\r\n">>}, State=#state{req_empty_lines=N}) ->
    start_parse_request(State#state{req_empty_lines=N + 1});
parse_request({http_error, <<"\n">>},
              State=#state{req_empty_lines=N, max_empty_lines=N}) ->
    {stop, {http_error, 400}, {error, {http_error, 400}}, State};
parse_request({http_error, <<"\n">>}, State=#state{req_empty_lines=N}) ->
    start_parse_request(State#state{req_empty_lines=N + 1}).

start_parse_request_header(State=#state{server_buffer=Buffer}) ->
    case erlang:decode_packet(httph_bin, Buffer, []) of
        {ok, Header, Rest} ->
            lager:debug("parse_request_header: ~p", [Header]),
            lager:debug("Rest: ~p", [Rest]),
            parse_request_header(Header, State#state{server_buffer=Rest});
        {more, _Length} ->
            wait_request_header(State)
    end.

wait_request_header(State=#state{server_socket=Socket, transport=Transport, timeout=T, server_buffer=Buffer}) ->
    {ok, Data} = Transport:recv(Socket, 0, T),
    start_parse_request_header(State#state{server_buffer= << Buffer/binary, Data/binary >>}).

parse_request_header({http_header, _I, 'Host', _R, RawHost}, State = #state{transport=Transport,
                                                                            http_req=Req=#http_req{uri=Uri=#http_uri{domain=undefined}}}) ->
    {ok,
     {http, _UserInfo, THost, Port, _Path, _Query}} = http_uri:parse("http://" ++ binary_to_list(RawHost)),
    Host = list_to_binary(THost),
    DefaultPort = agilitycache_http_protocol_parser:default_port(Transport:name()),


    State2 = case Port of
                 DefaultPort ->
                     State#state{http_req=Req#http_req{
                                            uri=Uri#http_uri{domain=Host, port=DefaultPort},
                                            headers=[{'Host', Host}|Req#http_req.headers]}};
                 _ ->
                     BinaryPort = list_to_binary(integer_to_list(Port)),
                     State#state{http_req=Req#http_req{
                                            uri=Uri#http_uri{domain=Host, port=Port},
                                            headers=[{'Host', << Host/binary, ":", BinaryPort/binary>>}|Req#http_req.headers]}}
             end,
    start_parse_request_header(State2);
%% Ignore Host headers if we already have it.
parse_request_header({http_header, _I, 'Host', _R, _V}, State) ->
    start_parse_request_header(State);
parse_request_header({http_header, _I, 'Connection', _R, Connection}, State = #state{http_req=Req}) ->
    ConnAtom = agilitycache_http_protocol_parser:response_connection_parse(Connection),
    start_parse_request_header(State#state{http_req=Req#http_req{connection=ConnAtom,
                                                                 headers=[{'Connection', Connection}|Req#http_req.headers]}});
parse_request_header({http_header, _I, Field, _R, Value}, State = #state{http_req=Req}) ->
    Field2 = agilitycache_http_protocol_parser:format_header(Field),
    start_parse_request_header(State#state{http_req=Req#http_req{headers=[{Field2, Value}|Req#http_req.headers]}});
%% The Host header is required in HTTP/1.1.
parse_request_header(http_eoh, State=#state{http_req=#http_req{uri=#http_uri{domain=undefined}}}) ->
    {stop, {http_error, 400}, {error, {http_error, 400}}, State};
parse_request_header(http_eoh, State) ->
    %% Ok, terminar aqui, e esperar envio!
    {reply, ok, State};
parse_request_header({http_error, Bin}, State) ->
    lager:debug("Bin: ~p", [Bin]),
    {stop, {http_error, 500}, {error, {http_error, 500}}, State}.
