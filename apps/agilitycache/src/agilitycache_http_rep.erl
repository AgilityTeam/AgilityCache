%% @doc HTTP request manipulation API.
%%
%% Almost all functions in this module return a new <em>Rep</em> variable.
%% It should always be used instead of the one used in your function call
%% because it keeps the state of the reply. It also allows AgilityCache to do
%% some lazy evaluation and cache results where possible.
-module(agilitycache_http_rep).

-export([
	 status/1, version/1, string/1,
	 peer/3,
	 header/2, header/3, headers/1,
	 cookie/2, cookie/3, cookies/1,
	 content_length/1
	]). %% Request API.

-export([
	 compact/1,
	 response_head/1,
	 response_head/3
	]). %% Misc API.

-include("include/http.hrl").

%% Request API.

%% @doc Return the HTTP method of the request.
-spec status(#http_rep{}) -> {http_status(), #http_rep{}}.
status(Rep) ->
    {Rep#http_rep.status, Rep}.

-spec string(#http_rep{}) -> {http_string(), #http_rep{}}.
string(Rep) ->
    {Rep#http_rep.string, Rep}.

%% @doc Return the HTTP version used for the request.
-spec version(#http_rep{}) -> {http_version(), #http_rep{}}.
version(Rep) ->
    {Rep#http_rep.version, Rep}.

%% @doc Return the peer address and port number of the remote host.
%%-spec peer(pid(), #http_rep{}) -> {{inet:ip_address(), inet:ip_port()}, #http_req{}}.
peer(Transport, Socket, Rep=#http_rep{peer=undefined}) ->
    {ok, Peer} = Transport:peername(Socket),
    {Peer, Rep#http_rep{peer=Peer}};
peer(_Transport, _Socket, Rep) ->
    {Rep#http_rep.peer, Rep}.

%% @equiv header(Name, Rep, undefined)
-spec header(atom() | binary(), #http_rep{})
	    -> {binary() | undefined, #http_rep{}}.
header(Name, Rep) when is_atom(Name) orelse is_binary(Name) ->
    header(Name, Rep, undefined).

%% @doc Return the header value for the given key, or a default if missing.
-spec header(atom() | binary(), #http_rep{}, Default)
	    -> {binary() | Default, #http_rep{}} when Default::any().
header(Name, Rep, Default) when is_atom(Name) orelse is_binary(Name) ->
    case lists:keyfind(Name, 1, Rep#http_rep.headers) of
	{Name, Value} -> {Value, Rep};
	false -> {Default, Rep}
    end.

%% @doc Return the full list of headers.
-spec headers(#http_rep{}) -> {http_headers(), #http_rep{}}.
headers(Rep) ->
    {Rep#http_rep.headers, Rep}.

-spec content_length(#http_rep{}) -> {binary() | integer(), #http_rep{}}.
content_length(Rep=#http_rep{content_length=undefined}) ->
    {Length, Rep2} = header('Content-Length', Rep),
    {Length, Rep2#http_rep{content_length=Length}};
content_length(Rep) ->
    {Rep#http_rep.content_length, Rep}.	

%% @equiv cookie(Name, Rep, undefined)
-spec cookie(binary(), #http_rep{})
	    -> {binary() | true | undefined, #http_rep{}}.
cookie(Name, Rep) when is_binary(Name) ->
    cookie(Name, Rep, undefined).

%% @doc Return the cookie value for the given key, or a default if
%% missing.
-spec cookie(binary(), #http_rep{}, Default)
	    -> {binary() | true | Default, #http_rep{}} when Default::any().
cookie(Name, Rep=#http_rep{cookies=undefined}, Default) when is_binary(Name) ->
    case header('Cookie', Rep) of
	{undefined, Rep2} ->
	    {Default, Rep2#http_rep{cookies=[]}};
	{RawCookie, Rep2} ->
	    Cookies = cowboy_cookies:parse_cookie(RawCookie),
	    cookie(Name, Rep2#http_rep{cookies=Cookies}, Default)
    end;
cookie(Name, Rep, Default) ->
    case lists:keyfind(Name, 1, Rep#http_rep.cookies) of
	{Name, Value} -> {Value, Rep};
	false -> {Default, Rep}
    end.

%% @doc Return the full list of cookie values.
-spec cookies(#http_rep{}) -> {list({binary(), binary() | true}), #http_rep{}}.
cookies(Rep=#http_rep{cookies=undefined}) ->
    case header('Cookie', Rep) of
	{undefined, Rep2} ->
	    {[], Rep2#http_rep{cookies=[]}};
	{RawCookie, Rep2} ->
	    Cookies = cowboy_cookies:parse_cookie(RawCookie),
	    cookies(Rep2#http_rep{cookies=Cookies})
    end;
cookies(Rep=#http_rep{cookies=Cookies}) ->
    {Cookies, Rep}.

%% Misc API.

%% @doc Compact the request data by removing all non-system information.
%%
%% This essentially removes the host, path, query string and headers.
%% Use it when you really need to save up memory, for example when having
%% many concurrent long-running connections.
-spec compact(#http_rep{}) -> #http_rep{}.
compact(Rep) ->
    Rep#http_rep{headers=[]}.

%% Internal.
-include_lib("eunit/include/eunit.hrl").

-spec parse_qs(binary()) -> list({binary(), binary() | true}).
parse_qs(<<>>) ->
    [];
parse_qs(Qs) ->
    URLDecode = fun(Bin) -> cowboy_http:urldecode(Bin, crash) end,
    cowboy_http_req:parse_qs(Qs, URLDecode).

-spec response_head(http_status(), http_headers(), http_headers()) -> iolist().
response_head(Status, Headers, DefaultHeaders) ->
    StatusLine = <<"HTTP/1.1 ", (agilitycache_http_protocol_parser:status(Status))/binary, "\r\n">>,
    Headers2 = [{agilitycache_http_protocol_parser:header_to_binary(Key), Value} || {Key, Value} <- Headers],
    Headers3 = lists:keysort(1, Headers2),
    Headers4 = lists:ukeymerge(1, Headers3, DefaultHeaders),
    Headers5 = [<< Key/binary, ": ", Value/binary, "\r\n" >>
		    || {Key, Value} <- Headers4],
    [StatusLine, Headers5, <<"\r\n">>].

response_head(Rep) ->
    response_head(Rep#http_rep.status, Rep#http_rep.headers, []).

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
