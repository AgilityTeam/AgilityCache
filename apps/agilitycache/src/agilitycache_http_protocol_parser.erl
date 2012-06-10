-module(agilitycache_http_protocol_parser).
-include("include/http.hrl").

-export([
	 version_to_connection/1,
   response_connection/2,
   response_connection_parse/1,
   response_proxy_connection/2,
   response_proxy_connection_parse/1,
   keepalive/2,
   keepalive_parse/2,
	 atom_to_connection/1,
	 default_port/1,
	 format_header/1,
	 status/1,
	 header_to_binary/1,
	 method_to_binary/1]).
%% Internal.

-spec version_to_connection(http_version()) -> keepalive | close.

version_to_connection({1, 1}) -> keepalive;
version_to_connection(_Any) -> close.

-spec response_connection(http_headers(), keepalive | close)
  -> keepalive | close.

response_connection([], Connection) ->
  Connection;
response_connection([{Name, Value}|Tail], Connection) ->
  case Name of
    'Connection' -> response_connection_parse(Value);
    Name when is_atom(Name) -> response_connection(Tail, Connection);
    Name ->
      Name2 = cowboy_bstr:to_lower(Name),
      case Name2 of
        <<"connection">> -> response_connection_parse(Value);
        _Any -> response_connection(Tail, Connection)
      end
  end.

-spec response_connection_parse(binary()) -> keepalive | close.

response_connection_parse(ReplyConn) ->
  Tokens = cowboy_http:nonempty_list(ReplyConn, fun cowboy_http:token/2),
  cowboy_http:connection_to_atom(Tokens).


-spec response_proxy_connection(http_headers(), keepalive | close)
  -> keepalive | close.

response_proxy_connection([], Connection) ->
  Connection;
response_proxy_connection([{Name, Value}|Tail], Connection) ->
  case Name of
    'Proxy-Connection' -> response_proxy_connection_parse(Value);
    Name when is_atom(Name) -> response_proxy_connection(Tail, Connection);
    Name ->
      Name2 = cowboy_bstr:to_lower(Name),
      case Name2 of
        <<"proxy-connection">> -> response_proxy_connection_parse(Value);
        _Any -> response_proxy_connection(Tail, Connection)
      end
  end.

-spec response_proxy_connection_parse(binary()) -> keepalive | close.

response_proxy_connection_parse(ReplyConn) ->
  Tokens = cowboy_http:nonempty_list(ReplyConn, fun cowboy_http:token/2),
  cowboy_http:connection_to_atom(Tokens).

-spec keepalive(list(), Default::any()) -> Default::any().

keepalive([], Default) ->
  Default;
keepalive([{Name, Value}|Tail], Default) ->
  case Name of
    'Keep-Alive' -> keepalive_parse(Value, Default);
    Name when is_atom(Name) -> keepalive(Tail, Default);
    Name ->
      Name2 = cowboy_bstr:to_lower(Name),
      case Name2 of
        <<"keep-alive">> -> keepalive_parse(Value, Default);
        _Any -> keepalive(Tail, Default)
      end
  end.

-spec keepalive_parse(list(), Default::any()) -> Default::any().

keepalive_parse(Terms, Default) ->
  Tokens = cowboy_http:list(Terms, fun (A, B) -> B(<<>>, A) end),
  %%lager:debug("Tokens: ~p~nTerms: ~p~n", [Tokens, Terms]),
  keepalive_parse_2(Tokens, Default).

-spec keepalive_parse_2(maybe_improper_list(),_) -> any().
keepalive_parse_2([], Default) ->
  Default;
keepalive_parse_2([ << "timeout=", Limit/binary>> |_Tail], _Default) ->
  list_to_integer(binary_to_list(Limit));
keepalive_parse_2([_Any|Tail], Default) ->
  %lager:debug("Tail: ~p~n", [Tail]),
  keepalive_parse_2(Tail, Default).



-spec atom_to_connection(keepalive) -> <<_:80>>;
			(close) -> <<_:40>>.

atom_to_connection(keepalive) ->
    <<"keep-alive">>;
atom_to_connection(close) ->
    <<"close">>.

-spec default_port(atom()) -> 80 | 443.

default_port(ssl) -> 443;
default_port(_) -> 80.

%% @todo While 32 should be enough for everybody, we should probably make
%%       this configurable or something.
-spec format_header(atom()) -> atom(); (binary()) -> binary().

format_header(Field) when is_atom(Field) ->
    Field;
format_header(Field) when byte_size(Field) =< 20; byte_size(Field) > 32 ->
    Field;
format_header(Field) ->
    format_header(Field, true, <<>>).

-spec format_header(binary(), boolean(), binary()) -> binary().

format_header(<<>>, _Any, Acc) ->
    Acc;
%% Replicate a bug in OTP for compatibility reasons when there's a - right
%% after another. Proper use should always be 'true' instead of 'not Bool'.
format_header(<< $-, Rest/bits >>, Bool, Acc) ->
    format_header(Rest, not Bool, << Acc/binary, $- >>);
format_header(<< C, Rest/bits >>, true, Acc) ->
    format_header(Rest, false, << Acc/binary, (cowboy_bstr:char_to_upper(C)) >>);
format_header(<< C, Rest/bits >>, false, Acc) ->
    format_header(Rest, false, << Acc/binary, (cowboy_bstr:char_to_lower(C)) >>).

-spec status(http_status()) -> binary().

status(100) -> <<"100 Continue">>;
status(101) -> <<"101 Switching Protocols">>;
status(102) -> <<"102 Processing">>;
status(200) -> <<"200 OK">>;
status(201) -> <<"201 Created">>;
status(202) -> <<"202 Accepted">>;
status(203) -> <<"203 Non-Authoritative Information">>;
status(204) -> <<"204 No Content">>;
status(205) -> <<"205 Reset Content">>;
status(206) -> <<"206 Partial Content">>;
status(207) -> <<"207 Multi-Status">>;
status(226) -> <<"226 IM Used">>;
status(300) -> <<"300 Multiple Choices">>;
status(301) -> <<"301 Moved Permanently">>;
status(302) -> <<"302 Found">>;
status(303) -> <<"303 See Other">>;
status(304) -> <<"304 Not Modified">>;
status(305) -> <<"305 Use Proxy">>;
status(306) -> <<"306 Switch Proxy">>;
status(307) -> <<"307 Temporary Redirect">>;
status(400) -> <<"400 Bad Request">>;
status(401) -> <<"401 Unauthorized">>;
status(402) -> <<"402 Payment Required">>;
status(403) -> <<"403 Forbidden">>;
status(404) -> <<"404 Not Found">>;
status(405) -> <<"405 Method Not Allowed">>;
status(406) -> <<"406 Not Acceptable">>;
status(407) -> <<"407 Proxy Authentication Required">>;
status(408) -> <<"408 Request Timeout">>;
status(409) -> <<"409 Conflict">>;
status(410) -> <<"410 Gone">>;
status(411) -> <<"411 Length Required">>;
status(412) -> <<"412 Precondition Failed">>;
status(413) -> <<"413 Request Entity Too Large">>;
status(414) -> <<"414 Request-URI Too Long">>;
status(415) -> <<"415 Unsupported Media Type">>;
status(416) -> <<"416 Requested Range Not Satisfiable">>;
status(417) -> <<"417 Expectation Failed">>;
status(418) -> <<"418 I'm a teapot">>;
status(422) -> <<"422 Unprocessable Entity">>;
status(423) -> <<"423 Locked">>;
status(424) -> <<"424 Failed Dependency">>;
status(425) -> <<"425 Unordered Collection">>;
status(426) -> <<"426 Upgrade Required">>;
status(500) -> <<"500 Internal Server Error">>;
status(501) -> <<"501 Not Implemented">>;
status(502) -> <<"502 Bad Gateway">>;
status(503) -> <<"503 Service Unavailable">>;
status(504) -> <<"504 Gateway Timeout">>;
status(505) -> <<"505 HTTP Version Not Supported">>;
status(506) -> <<"506 Variant Also Negotiates">>;
status(507) -> <<"507 Insufficient Storage">>;
status(510) -> <<"510 Not Extended">>;
status(B) when is_binary(B) -> B.

-spec header_to_binary(http_header()) -> binary().

header_to_binary('Cache-Control') -> <<"Cache-Control">>;
header_to_binary('Connection') -> <<"Connection">>;
header_to_binary('Date') -> <<"Date">>;
header_to_binary('Pragma') -> <<"Pragma">>;
header_to_binary('Transfer-Encoding') -> <<"Transfer-Encoding">>;
header_to_binary('Upgrade') -> <<"Upgrade">>;
header_to_binary('Via') -> <<"Via">>;
header_to_binary('Accept') -> <<"Accept">>;
header_to_binary('Accept-Charset') -> <<"Accept-Charset">>;
header_to_binary('Accept-Encoding') -> <<"Accept-Encoding">>;
header_to_binary('Accept-Language') -> <<"Accept-Language">>;
header_to_binary('Authorization') -> <<"Authorization">>;
header_to_binary('From') -> <<"From">>;
header_to_binary('Host') -> <<"Host">>;
header_to_binary('If-Modified-Since') -> <<"If-Modified-Since">>;
header_to_binary('If-Match') -> <<"If-Match">>;
header_to_binary('If-None-Match') -> <<"If-None-Match">>;
header_to_binary('If-Range') -> <<"If-Range">>;
header_to_binary('If-Unmodified-Since') -> <<"If-Unmodified-Since">>;
header_to_binary('Max-Forwards') -> <<"Max-Forwards">>;
header_to_binary('Proxy-Authorization') -> <<"Proxy-Authorization">>;
header_to_binary('Range') -> <<"Range">>;
header_to_binary('Referer') -> <<"Referer">>;
header_to_binary('User-Agent') -> <<"User-Agent">>;
header_to_binary('Age') -> <<"Age">>;
header_to_binary('Location') -> <<"Location">>;
header_to_binary('Proxy-Authenticate') -> <<"Proxy-Authenticate">>;
header_to_binary('Public') -> <<"Public">>;
header_to_binary('Retry-After') -> <<"Retry-After">>;
header_to_binary('Server') -> <<"Server">>;
header_to_binary('Vary') -> <<"Vary">>;
header_to_binary('Warning') -> <<"Warning">>;
header_to_binary('Www-Authenticate') -> <<"Www-Authenticate">>;
header_to_binary('Allow') -> <<"Allow">>;
header_to_binary('Content-Base') -> <<"Content-Base">>;
header_to_binary('Content-Encoding') -> <<"Content-Encoding">>;
header_to_binary('Content-Language') -> <<"Content-Language">>;
header_to_binary('Content-Length') -> <<"Content-Length">>;
header_to_binary('Content-Location') -> <<"Content-Location">>;
header_to_binary('Content-Md5') -> <<"Content-Md5">>;
header_to_binary('Content-Range') -> <<"Content-Range">>;
header_to_binary('Content-Type') -> <<"Content-Type">>;
header_to_binary('Etag') -> <<"Etag">>;
header_to_binary('Expires') -> <<"Expires">>;
header_to_binary('Last-Modified') -> <<"Last-Modified">>;
header_to_binary('Accept-Ranges') -> <<"Accept-Ranges">>;
header_to_binary('Set-Cookie') -> <<"Set-Cookie">>;
header_to_binary('Set-Cookie2') -> <<"Set-Cookie2">>;
header_to_binary('X-Forwarded-For') -> <<"X-Forwarded-For">>;
header_to_binary('Cookie') -> <<"Cookie">>;
header_to_binary('Keep-Alive') -> <<"Keep-Alive">>;
header_to_binary('Proxy-Connection') -> <<"Proxy-Connection">>;
header_to_binary(B) when is_binary(B) -> B.

-spec method_to_binary(http_method()) -> binary().

method_to_binary('OPTIONS') -> <<"OPTIONS">>;
method_to_binary('GET') -> <<"GET">>;
method_to_binary('HEAD') -> <<"HEAD">>;
method_to_binary('POST') -> <<"POST">>;
method_to_binary('PUT') -> <<"PUT">>;
method_to_binary('DELETE') -> <<"DELETE">>;
method_to_binary('TRACE') -> <<"TRACE">>;
method_to_binary(B) when is_binary(B) -> B.

%% Tests.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

format_header_test_() ->
    %% {Header, Result}
    Tests = [
	     {<<"Sec-Websocket-Version">>, <<"Sec-Websocket-Version">>},
	     {<<"Sec-WebSocket-Version">>, <<"Sec-Websocket-Version">>},
	     {<<"sec-websocket-version">>, <<"Sec-Websocket-Version">>},
	     {<<"SEC-WEBSOCKET-VERSION">>, <<"Sec-Websocket-Version">>},
	     %% These last tests ensures we're formatting headers exactly like OTP.
	     %% Even though it's dumb, it's better for compatibility reasons.
	     {<<"Sec-WebSocket--Version">>, <<"Sec-Websocket--version">>},
	     {<<"Sec-WebSocket---Version">>, <<"Sec-Websocket---Version">>}
	    ],
    [{H, fun() -> R = format_header(H) end} || {H, R} <- Tests].

-endif.
