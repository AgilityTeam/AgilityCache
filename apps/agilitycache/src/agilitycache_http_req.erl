%% @doc HTTP request manipulation API.
%%
%% Almost all functions in this module return a new <em>Req</em> variable.
%% It should always be used instead of the one used in your function call
%% because it keeps the state of the request. It also allows AgilityCache to do
%% some lazy evaluation and cache results where possible.
-module(agilitycache_http_req).

-export([
	 method/3, version/3, peer/3,
	 host/3, raw_host/3, port/3,
	 path/3, raw_path/3,
	 qs_val/4, qs_val/5, qs_vals/3, raw_qs/3,
	 header/4, header/5, headers/3,
	 cookie/4, cookie/5, cookies/3,
	 content_length/3
	]). %% Request API.

-export([
	 reply/6, 
	 start_chunked_reply/5, send_chunk/4, stop_chunked_reply/3,
	 start_reply/5
	]). %% Response API.

-export([
	 compact/1,
	 request_head/1
	]). %% Misc API.

-include("include/http.hrl").
%% Request API.

%% @doc Return the HTTP method of the request.
-spec method(module(), inet:socket(), #http_req{}) -> {http_method(), #http_req{}}.
method(Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:method(agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

%% @doc Return the HTTP version used for the request.
-spec version(module(), inet:socket(), #http_req{}) -> {http_version(), #http_req{}}.
version(Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:version(agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

%% @doc Return the peer address and port number of the remote host.
%%-spec peer(pid(), #http_req{}) -> {{inet:ip_address(), inet:ip_port()}, #http_req{}}.
peer(Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:peer(agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

%% @doc Return the tokens for the hostname requested.
%%-spec host(#http_req{}) -> {cowboy_dispatcher:tokens(), #http_req{}}.
host(Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:host(agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

%% @doc Return the raw host directly taken from the request.
%%-spec raw_host(#http_req{}) -> {binary(), #http_req{}}.
raw_host(Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:raw_host(agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

%% @doc Return the port used for this request.
%%-spec port(#http_req{}) -> {inet:ip_port(), #http_req{}}.
port(Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:port(agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

%% @doc Return the tokens for the path requested.
%%-spec path(#http_req{}) -> {cowboy_dispatcher:tokens(), #http_req{}}.
path(Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:path(agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

%% @doc Return the raw path directly taken from the request.
%%-spec raw_path(#http_req{}) -> {binary(), #http_req{}}.
raw_path(Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:raw_path(agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

qs_val(Name, Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:qs_val(Name, agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

qs_val(Name, Transport, Socket, Req, Default) ->
    {Result, CowboyReq} = cowboy_http_req:qs_val(Name, agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req), Default),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.
    
qs_vals(Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:qs_vals(agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.
    
raw_qs(Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:raw_qs(agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

header(Name, Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:header(Name, agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

header(Name, Transport, Socket, Req, Default) ->
    {Result, CowboyReq} = cowboy_http_req:header(Name, agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req), Default),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

headers(Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:headers(agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

cookie(Name, Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:cookie(Name, agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

cookie(Name, Transport, Socket, Req, Default) ->
    {Result, CowboyReq} = cowboy_http_req:cookie(Name, agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req), Default),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

cookies(Transport, Socket, Req) ->
    {Result, CowboyReq} = cowboy_http_req:cookies(agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
    {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.
    
-spec content_length(module(), inet:socket(), #http_req{}) -> {undefined | non_neg_integer() | binary(), #http_req{}}.
content_length(Transport, Socket, Req=#http_req{content_length=undefined}) ->
    {Length, Req} = header('Content-Length', Transport, Socket, Req),
    {Length, Req#http_req{content_length=Length}};
content_length(_Transport, _Socket, Req) ->
    {Req#http_req.content_length, Req}.

%% Response API.

%% @doc Send a reply to the client.
%%-spec reply(pid(), http_status(), http_headers(), iodata(), #http_req{})
%%	   -> {ok, #http_req{}}.
reply(Transport, Socket, Code, Headers, Body, Req) ->
  {Result, CowboyReq} = cowboy_http_req:reply(Code, Headers, Body, agilitycache_http_req_conversor:req_to_cowboy(Transport, Socket, Req)),
  {Result, agilitycache_http_req_conversor:req_to_agilitycache(CowboyReq)}.

%% @doc Send a reply to the client.
%%-spec start_reply(pid(), http_status(), http_headers(), integer()|binary(), #http_req{})
%%		 -> {ok, #http_req{}}.
start_reply(HttpServer, Code, Headers, Length, Req) when is_integer(Length) ->
    start_reply(HttpServer, Code, Headers, list_to_binary(integer_to_list(Length)), Req);
start_reply(HttpServer, Code, Headers, Length, Req=#http_req{connection=Connection, method=Method}) ->
    RespConn = agilitycache_http_protocol_parser:response_connection(Headers, Connection),
    MyHeaders = case Length of
      undefined ->
        [
          {<<"Connection">>, agilitycache_http_protocol_parser:atom_to_connection(RespConn)},
          {<<"Date">>, cowboy_clock:rfc1123()},
          {<<"Server">>, <<"AgilityCache">>}
        ];
      _ when is_binary(Length) ->
        [      
          {<<"Connection">>, agilitycache_http_protocol_parser:atom_to_connection(RespConn)},      
          {<<"Date">>, cowboy_clock:rfc1123()},
          {<<"Content-Length">>, Length},
          {<<"Server">>, <<"AgilityCache">>}
        ]
    end,
    
    Head = agilitycache_http_rep:response_head(Code, Headers, MyHeaders),
    %% @todo arrumar isso pra fazer um match mais bonitinho
    %% ou passar isso pra frente
    case agilitycache_http_server:send_data(Head, HttpServer) of
      {ok, HttpServer0} ->
        case Method of
          'HEAD' -> {ok, Req#http_req{connection=RespConn, resp_state=done}, HttpServer0};
          _ -> {ok, Req#http_req{connection=RespConn, resp_state=waiting}, HttpServer0}
        end;
      {error, _, _} = Error ->
        Error
    end.

%% @doc Initiate the sending of a chunked reply to the client.
%% @see agilitycache_http_req:chunk/2
%%-spec start_chunked_reply(pid(), http_status(), http_headers(), #http_req{})
%%			 -> {ok, #http_req{}}.
start_chunked_reply(Transport, Socket, Code, Headers, Req=#http_req{method='HEAD', resp_state=waiting}) ->
    Head = agilitycache_http_rep:response_head(Code, Headers, [
							       {<<"Date">>, cowboy_clock:rfc1123()},
							       {<<"Server">>, <<"AgilityCache">>}
							      ]),
    case Transport:send(Socket, Head) of
	ok ->
            {ok, Req#http_req{resp_state=done}};
	{error, closed} ->
            %% @todo Eu devia alertar sobre isso, não?
            {ok, Req#http_req{resp_state=done}};
	{error, _} = Error ->
            Error
    end;
start_chunked_reply(Transport, Socket, Code, Headers, Req=#http_req{resp_state=waiting}) ->
    Head = agilitycache_http_rep:response_head(Code, Headers, [
							       {<<"Connection">>, <<"close">>},
							       {<<"Transfer-Encoding">>, <<"chunked">>},
							       {<<"Date">>, cowboy_clock:rfc1123()},
							       {<<"Server">>, <<"AgilityCache">>}
							      ]),
    case Transport:send(Socket, Head) of
	ok ->
            {ok, Req#http_req{resp_state=chunks}};
	{error, closed} ->
            %% @todo Eu devia alertar sobre isso, não?
            {ok, Req#http_req{resp_state=done}};
	{error, _} = Error ->
            Error
    end.

%% @doc Send a chunk of data.
%%
%% A chunked reply must have been initiated before calling this function.
%%-spec send_chunk(pid(), iodata(), #http_req{}) -> ok.
send_chunk(_Transport, _Socket, _Data, #http_req{method='HEAD'}) ->
    ok;
send_chunk(Transport, Socket, Data, #http_req{resp_state=chunks}) ->
    case Transport:send(Socket, [integer_to_list(iolist_size(Data), 16), <<"\r\n">>, Data, <<"\r\n">>]) of
	ok ->
            ok;
	{error, closed} ->
            %% @todo Eu devia alertar sobre isso, não?
            ok;
	{error, _} = Error ->
            Error
    end.
%%-spec stop_chunked_reply(pid(), #http_req{}) -> ok.
stop_chunked_reply(Transport, Socket, #http_req{resp_state=chunks}) ->
    case Transport:send(Socket, <<"0\r\n\r\n">>) of
	ok ->
	    ok;
	{error, closed} ->
	    %% @todo Eu devia alertar sobre isso, não?
	    ok;
	{error, _} = Error ->
	    Error
    end.

%% Misc API.

%% @doc Compact the request data by removing all non-system information.
%%
%% This essentially removes the host, path, query string and headers.
%% Use it when you really need to save up memory, for example when having
%% many concurrent long-running connections.
-spec compact(#http_req{}) -> #http_req{}.
compact(Req) ->
    Req#http_req{host=undefined, path=undefined,
		 qs_vals=undefined, raw_qs=undefined,
		 headers=[]}.

%% Internal.


-spec request_head(#http_req{}) -> iolist().
request_head(Req) ->
    {Major, Minor} = Req#http_req.version,
    Majorb = list_to_binary(integer_to_list(Major)),
    Minorb = list_to_binary(integer_to_list(Minor)),
    Method = agilitycache_http_protocol_parser:method_to_binary(Req#http_req.method),
    Path1= Req#http_req.raw_path,
    Qs = Req#http_req.raw_qs,
    Path = case Qs of
	       <<>> ->
		   Path1;
	       _ ->
		   <<Path1/binary, "?" , Qs/binary>>
	   end,
    RequestLine = <<Method/binary, " ", Path/binary, " HTTP/", Majorb/binary, ".", Minorb/binary, "\r\n">>,
    Headers2 = [{agilitycache_http_protocol_parser:header_to_binary(Key), Value} || {Key, Value} <- Req#http_req.headers],
    Headers = [<< Key/binary, ": ", Value/binary, "\r\n" >> || {Key, Value} <- Headers2],
    [RequestLine, Headers, <<"\r\n">>].

