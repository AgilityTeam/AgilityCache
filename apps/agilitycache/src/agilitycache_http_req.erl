%% @doc HTTP request manipulation API.
%%
%% Almost all functions in this module return a new <em>Req</em> variable.
%% It should always be used instead of the one used in your function call
%% because it keeps the state of the request. It also allows AgilityCache to do
%% some lazy evaluation and cache results where possible.
-module(agilitycache_http_req).

-export([
	method/1, version/1, peer/1,
	host/1, raw_host/1, port/1,
	path/1, raw_path/1,
	qs_val/2, qs_val/3, qs_vals/1, raw_qs/1,
	header/2, header/3, headers/1,
	cookie/2, cookie/3, cookies/1
]). %% Request API.

-export([
	body/1, body/2, body_qs/1
]). %% Request Body API.

-export([
	reply/4, chunked_reply/3, chunk/2,
	start_reply/4, send_reply/2
]). %% Response API.

-export([
	compact/1,
  request_head/1
]). %% Misc API.

-include("include/http.hrl").
-include_lib("eunit/include/eunit.hrl").

%% Request API.

%% @doc Return the HTTP method of the request.
-spec method(#http_req{}) -> {http_method(), #http_req{}}.
method(Req) ->
	{Req#http_req.method, Req}.

%% @doc Return the HTTP version used for the request.
-spec version(#http_req{}) -> {http_version(), #http_req{}}.
version(Req) ->
	{Req#http_req.version, Req}.

%% @doc Return the peer address and port number of the remote host.
-spec peer(#http_req{}) -> {{inet:ip_address(), inet:ip_port()}, #http_req{}}.
peer(Req=#http_req{socket=Socket, transport=Transport, peer=undefined}) ->
	{ok, Peer} = Transport:peername(Socket),
	{Peer, Req#http_req{peer=Peer}};
peer(Req) ->
	{Req#http_req.peer, Req}.

%% @doc Return the tokens for the hostname requested.
-spec host(#http_req{}) -> {agilitycache_dispatcher:path_tokens(), #http_req{}}.
host(Req) ->
	{Req#http_req.host, Req}.

%% @doc Return the raw host directly taken from the request.
-spec raw_host(#http_req{}) -> {binary(), #http_req{}}.
raw_host(Req) ->
	{Req#http_req.raw_host, Req}.

%% @doc Return the port used for this request.
-spec port(#http_req{}) -> {inet:ip_port(), #http_req{}}.
port(Req) ->
	{Req#http_req.port, Req}.

%% @doc Return the tokens for the path requested.
-spec path(#http_req{}) -> {agilitycache_dispatcher:path_tokens(), #http_req{}}.
path(Req) ->
	{Req#http_req.path, Req}.

%% @doc Return the raw path directly taken from the request.
-spec raw_path(#http_req{}) -> {binary(), #http_req{}}.
raw_path(Req) ->
	{Req#http_req.raw_path, Req}.

%% @equiv qs_val(Name, Req, undefined)
-spec qs_val(binary(), #http_req{})
	-> {binary() | true | undefined, #http_req{}}.
qs_val(Name, Req) when is_binary(Name) ->
	qs_val(Name, Req, undefined).

%% @doc Return the query string value for the given key, or a default if
%% missing.
-spec qs_val(binary(), #http_req{}, Default)
	-> {binary() | true | Default, #http_req{}} when Default::any().
qs_val(Name, Req=#http_req{raw_qs=RawQs, qs_vals=undefined}, Default)
		when is_binary(Name) ->
	QsVals = parse_qs(RawQs),
	qs_val(Name, Req#http_req{qs_vals=QsVals}, Default);
qs_val(Name, Req, Default) ->
	case lists:keyfind(Name, 1, Req#http_req.qs_vals) of
		{Name, Value} -> {Value, Req};
		false -> {Default, Req}
	end.

%% @doc Return the full list of query string values.
-spec qs_vals(#http_req{}) -> {list({binary(), binary() | true}), #http_req{}}.
qs_vals(Req=#http_req{raw_qs=RawQs, qs_vals=undefined}) ->
	QsVals = parse_qs(RawQs),
	qs_vals(Req#http_req{qs_vals=QsVals});
qs_vals(Req=#http_req{qs_vals=QsVals}) ->
	{QsVals, Req}.

%% @doc Return the raw query string directly taken from the request.
-spec raw_qs(#http_req{}) -> {binary(), #http_req{}}.
raw_qs(Req) ->
	{Req#http_req.raw_qs, Req}.

%% @equiv header(Name, Req, undefined)
-spec header(atom() | binary(), #http_req{})
	-> {binary() | undefined, #http_req{}}.
header(Name, Req) when is_atom(Name) orelse is_binary(Name) ->
	header(Name, Req, undefined).

%% @doc Return the header value for the given key, or a default if missing.
-spec header(atom() | binary(), #http_req{}, Default)
	-> {binary() | Default, #http_req{}} when Default::any().
header(Name, Req, Default) when is_atom(Name) orelse is_binary(Name) ->
	case lists:keyfind(Name, 1, Req#http_req.headers) of
		{Name, Value} -> {Value, Req};
		false -> {Default, Req}
	end.

%% @doc Return the full list of headers.
-spec headers(#http_req{}) -> {http_headers(), #http_req{}}.
headers(Req) ->
	{Req#http_req.headers, Req}.

%% @equiv cookie(Name, Req, undefined)
-spec cookie(binary(), #http_req{})
	-> {binary() | true | undefined, #http_req{}}.
cookie(Name, Req) when is_binary(Name) ->
	cookie(Name, Req, undefined).

%% @doc Return the cookie value for the given key, or a default if
%% missing.
-spec cookie(binary(), #http_req{}, Default)
	-> {binary() | true | Default, #http_req{}} when Default::any().
cookie(Name, Req=#http_req{cookies=undefined}, Default) when is_binary(Name) ->
	case header('Cookie', Req) of
		{undefined, Req2} ->
			{Default, Req2#http_req{cookies=[]}};
		{RawCookie, Req2} ->
			Cookies = cowboy_cookies:parse_cookie(RawCookie),
			cookie(Name, Req2#http_req{cookies=Cookies}, Default)
	end;
cookie(Name, Req, Default) ->
	case lists:keyfind(Name, 1, Req#http_req.cookies) of
		{Name, Value} -> {Value, Req};
		false -> {Default, Req}
	end.

%% @doc Return the full list of cookie values.
-spec cookies(#http_req{}) -> {list({binary(), binary() | true}), #http_req{}}.
cookies(Req=#http_req{cookies=undefined}) ->
	case header('Cookie', Req) of
		{undefined, Req2} ->
			{[], Req2#http_req{cookies=[]}};
		{RawCookie, Req2} ->
			Cookies = cowboy_cookies:parse_cookie(RawCookie),
			cookies(Req2#http_req{cookies=Cookies})
	end;
cookies(Req=#http_req{cookies=Cookies}) ->
	{Cookies, Req}.

%% Request Body API.

%% @doc Return the full body sent with the request, or <em>{error, badarg}</em>
%% if no <em>Content-Length</em> is available.
%% @todo We probably want to allow a max length.
-spec body(#http_req{}) -> {ok, binary(), #http_req{}} | {error, atom()}.
body(Req) ->
	{Length, Req2} = agilitycache_http_req:header('Content-Length', Req),
	case Length of
		undefined -> {error, badarg};
		_Any ->
			Length2 = list_to_integer(binary_to_list(Length)),
			body(Length2, Req2)
	end.

%% @doc Return <em>Length</em> bytes of the request body.
%%
%% You probably shouldn't be calling this function directly, as it expects the
%% <em>Length</em> argument to be the full size of the body, and will consider
%% the body to be fully read from the socket.
%% @todo We probably want to configure the timeout.
-spec body(non_neg_integer(), #http_req{})
	-> {ok, binary(), #http_req{}} | {error, atom()}.
body(Length, Req=#http_req{body_state=waiting, buffer=Buffer})
		when Length =:= byte_size(Buffer) ->
	{ok, Buffer, Req#http_req{body_state=done, buffer= <<>>}};
body(Length, Req=#http_req{socket=Socket, transport=Transport,
		body_state=waiting, buffer=Buffer})
		when is_integer(Length) andalso Length > byte_size(Buffer) ->
	case Transport:recv(Socket, Length - byte_size(Buffer), 5000) of
		{ok, Body} -> {ok, << Buffer/binary, Body/binary >>,
			Req#http_req{body_state=done, buffer= <<>>}};
		{error, Reason} -> {error, Reason}
	end.

%% @doc Return the full body sent with the reqest, parsed as an
%% application/x-www-form-urlencoded string. Essentially a POST query string.
-spec body_qs(#http_req{}) -> {list({binary(), binary() | true}), #http_req{}}.
body_qs(Req) ->
	{ok, Body, Req2} = body(Req),
	{parse_qs(Body), Req2}.

%% Response API.

%% @doc Send a reply to the client.
-spec reply(http_status(), http_headers(), iodata(), #http_req{})
	-> {ok, #http_req{}}.
reply(Code, Headers, Body, Req=#http_req{socket=Socket,
		transport=Transport, connection=Connection,
		method=Method, resp_state=waiting}) ->
	Head = agilitycache_http_rep:response_head(Code, Headers, [
		{<<"Connection">>, agilitycache_http_protocol_parser:atom_to_connection(Connection)},
		{<<"Content-Length">>,
			list_to_binary(integer_to_list(iolist_size(Body)))},
		{<<"Date">>, cowboy_clock:rfc1123()},
		{<<"Server">>, <<"AgilityCache">>}
	]),
	case Method of
		'HEAD' -> Transport:send(Socket, Head);
		_ -> Transport:send(Socket, [Head, Body])
	end,
	{ok, Req#http_req{resp_state=done}}.
	
%% @doc Send a reply to the client.
-spec start_reply(http_status(), http_headers(), integer()|binary(), #http_req{})
	-> {ok, #http_req{}}.
start_reply(Code, Headers, Length, Req=#http_req{socket=Socket,
		transport=Transport, connection=Connection,
		method=Method, resp_state=waiting}) when is_binary(Length) ->
	Head = agilitycache_http_rep:response_head(Code, Headers, [
		{<<"Connection">>, agilitycache_http_protocol_parser:atom_to_connection(Connection)},
		{<<"Content-Length">>,Length},
		{<<"Date">>, cowboy_clock:rfc1123()},
		{<<"Server">>, <<"AgilityCache">>}
	]),
	case Method of
		'HEAD' -> 
			Transport:send(Socket, Head),
			{ok, Req#http_req{resp_state=done}};
		_ -> 
			Transport:send(Socket, Head),
			{ok, Req#http_req{resp_state=waiting}}
	end;
start_reply(Code, Headers, Length, Req=#http_req{socket=Socket,
		transport=Transport, connection=Connection,
		method=Method, resp_state=waiting}) when is_integer(Length) ->
	Head = agilitycache_http_rep:response_head(Code, Headers, [
		{<<"Connection">>, agilitycache_http_protocol_parser:atom_to_connection(Connection)},
		{<<"Content-Length">>,
			list_to_binary(integer_to_list(Length))},
		{<<"Date">>, cowboy_clock:rfc1123()},
		{<<"Server">>, <<"AgilityCache">>}
	]),
	case Method of
		'HEAD' -> 
			Transport:send(Socket, Head),
			{ok, Req#http_req{resp_state=done}};
		_ -> 
			Transport:send(Socket, Head),
			{ok, Req#http_req{resp_state=waiting}}
	end.
	
-spec send_reply(iodata(), #http_req{}) -> ok.
send_reply(_Data, #http_req{socket=_Socket, transport=_Transport, method='HEAD'}) ->
	ok;
send_reply(Data, #http_req{socket=Socket, transport=Transport, resp_state=waiting}) ->
	Transport:send(Socket, Data).
	

%% @doc Initiate the sending of a chunked reply to the client.
%% @see agilitycache_http_req:chunk/2
-spec chunked_reply(http_status(), http_headers(), #http_req{})
	-> {ok, #http_req{}}.
chunked_reply(Code, Headers, Req=#http_req{socket=Socket, transport=Transport,
		method='HEAD', resp_state=waiting}) ->
	Head = agilitycache_http_rep:response_head(Code, Headers, [
		{<<"Date">>, cowboy_clock:rfc1123()},
		{<<"Server">>, <<"AgilityCache">>}
	]),
	Transport:send(Socket, Head),
	{ok, Req#http_req{resp_state=done}};
chunked_reply(Code, Headers, Req=#http_req{socket=Socket, transport=Transport,
		resp_state=waiting}) ->
	Head = agilitycache_http_rep:response_head(Code, Headers, [
		{<<"Connection">>, <<"close">>},
		{<<"Transfer-Encoding">>, <<"chunked">>},
		{<<"Date">>, cowboy_clock:rfc1123()},
		{<<"Server">>, <<"AgilityCache">>}
	]),
	Transport:send(Socket, Head),
	{ok, Req#http_req{resp_state=chunks}}.

%% @doc Send a chunk of data.
%%
%% A chunked reply must have been initiated before calling this function.
-spec chunk(iodata(), #http_req{}) -> ok.
chunk(_Data, #http_req{socket=_Socket, transport=_Transport, method='HEAD'}) ->
	ok;
chunk(Data, #http_req{socket=Socket, transport=Transport, resp_state=chunks}) ->
	Transport:send(Socket, [integer_to_list(iolist_size(Data), 16),
		<<"\r\n">>, Data, <<"\r\n">>]).

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

-spec parse_qs(binary()) -> list({binary(), binary() | true}).
parse_qs(<<>>) ->
	[];
parse_qs(Qs) ->
	Tokens = binary:split(Qs, <<"&">>, [global, trim]),
	[case binary:split(Token, <<"=">>) of
		[Token] -> {quoted:from_url(Token), true};
		[Name, Value] -> {quoted:from_url(Name), quoted:from_url(Value)}
	end || Token <- Tokens].

-spec request_head(#http_req{}) -> iolist().
request_head(Req) ->
  {Major, Minor} = Req#http_req.version,
  Majorb = list_to_binary(integer_to_list(Major)),
  Minorb = list_to_binary(integer_to_list(Minor)),
  error_logger:info_msg("Oia eu: ~p:~p!", [?MODULE, ?LINE]),
  Method = agilitycache_http_protocol_parser:method_to_binary(Req#http_req.method),
  error_logger:info_msg("Oia eu: ~p:~p!", [?MODULE, ?LINE]),
  Path= Req#http_req.raw_path,
  error_logger:info_msg("Oia eu: ~p:~p!", [?MODULE, ?LINE]),
  RequestLine = <<Method/binary, " ", Path/binary, " HTTP/", Majorb/binary, ".", Minorb/binary, "\r\n">>,
  error_logger:info_msg("Oia eu: ~p:~p!", [?MODULE, ?LINE]),
  Headers2 = [{agilitycache_http_protocol_parser:header_to_binary(Key), Value} || {Key, Value} <- Req#http_req.headers],
  Headers = [<< Key/binary, ": ", Value/binary, "\r\n" >> || {Key, Value} <- Headers2],
  error_logger:info_msg("Oia eu: ~p:~p!", [?MODULE, ?LINE]),
  [RequestLine, Headers, <<"\r\n">>].

%% Tests.

-ifdef(TEST).

parse_qs_test_() ->
	%% {Qs, Result}
	Tests = [
		{<<"">>, []},
		{<<"a=b">>, [{<<"a">>, <<"b">>}]},
		{<<"aaa=bbb">>, [{<<"aaa">>, <<"bbb">>}]},
		{<<"a&b">>, [{<<"a">>, true}, {<<"b">>, true}]},
		{<<"a=b&c&d=e">>, [{<<"a">>, <<"b">>},
			{<<"c">>, true}, {<<"d">>, <<"e">>}]},
		{<<"a=b=c=d=e&f=g">>, [{<<"a">>, <<"b=c=d=e">>}, {<<"f">>, <<"g">>}]},
		{<<"a+b=c+d">>, [{<<"a b">>, <<"c d">>}]}
	],
	[{Qs, fun() -> R = parse_qs(Qs) end} || {Qs, R} <- Tests].

-endif.
