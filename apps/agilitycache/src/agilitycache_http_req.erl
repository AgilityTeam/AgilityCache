%% @doc HTTP request manipulation API.
%%
%% Almost all functions in this module return a new <em>Req</em> variable.
%% It should always be used instead of the one used in your function call
%% because it keeps the state of the request. It also allows AgilityCache to do
%% some lazy evaluation and cache results where possible.
-module(agilitycache_http_req).

-export([
         method/1,
         version/1,
         peer/1,
         uri/1,
         headers/1,
         connection/1,
         content_length/1,
         header/2,
         header/3,
         uri_domain/1,
         uri_port/1,
         uri_path/1,
         uri_query_string/1
        ]).

-export([
         reply/5,
         start_reply/5
        ]). %% Response API.

-export([
         request_head/1
        ]). %% Misc API.

-include("http.hrl").

-spec method(#http_req{}) -> {http_method(), #http_req{}}.
method(#http_req{ method = Method} = Req) ->
	{Method, Req}.

-spec version(#http_req{}) -> {http_version(), #http_req{}}.
version(#http_req{ version = Version} = Req) ->
	{Version, Req}.

%% Pré-calculado ao iniciar conexão
-spec peer(#http_req{}) -> {{inet:ip_address(), inet:ip_port()}, #http_req{}}.
peer(#http_req{ peer = Peer} = Req) ->
	{Peer, Req}.

-spec uri(#http_req{}) -> {#http_uri{}, #http_req{}}.
uri(#http_req{ uri = Uri} = Req) ->
	{Uri, Req}.
-spec uri_domain(#http_req{}) -> {undefined | binary(), #http_req{}}.
uri_domain(#http_req{ uri = #http_uri{ domain = Domain} } = Req) ->
	{Domain, Req}.
-spec uri_port(#http_req{}) -> {inet:ip_port(), #http_req{}}.
uri_port(#http_req{ uri = #http_uri{ port = Port} } = Req) ->
	{Port, Req}.
-spec uri_path(#http_req{}) -> {iodata(), #http_req{}}.
uri_path(#http_req{ uri = #http_uri{ path = Path} } = Req) ->
	{Path, Req}.
-spec uri_query_string(#http_req{}) -> {iodata(), #http_req{}}.
uri_query_string(#http_req{ uri = #http_uri{ query_string = Qs} } = Req) ->
	{Qs, Req}.

-spec headers(#http_req{}) -> {http_headers(), #http_req{}}.
headers(#http_req{ headers = Headers} = Req) ->
	{Headers, Req}.

-spec connection(#http_req{}) -> {keepalive | close, #http_req{}}.
connection(#http_req{ connection = Connection} = Req) ->
	{Connection, Req}.

-spec content_length(#http_req{}) ->
		                    {undefined | non_neg_integer(), #http_req{}}.
content_length(#http_req{content_length=undefined} = Req) ->
	{Length, Req1} = case header('Content-Length', Req) of
		                 {L1, Req_1} when is_binary(L1) ->
                                                % Talvez iolist_to_binary seja desnecessário, mas é bom para manter certinho o input com iolist/iodata
			                 {list_to_integer(
			                      binary_to_list(
			                          iolist_to_binary(L1))), Req_1};
		                 {_, Req_2} ->
			                 {invalid, Req_2}
	                 end,
	case Length of
		invalid ->
			{undefined, Req1#http_req{content_length=invalid}};
		_ ->
			{Length, Req1#http_req{content_length=Length}}
	end;
%% estado invalid = Content-Length: -1,
%% serve para não ficar escaneando toda hora
content_length(#http_req{content_length=invalid} = Req) ->
	{undefined, Req};
content_length(#http_req{content_length=ContentLength} = Req) ->
	{ContentLength, Req}.

%% @equiv header(Name, Req, undefined)
-spec header(http_header(), #http_req{})
            -> {iodata() | undefined, #http_req{}}.
header(Name, Req) when is_atom(Name) orelse is_binary(Name) ->
	header(Name, Req, undefined).

%% @doc Return the header value for the given key, or a default if missing.
-spec header(http_header(), #http_req{}, Default)
            -> {iodata() | Default, #http_req{}} when Default::any().
header(Name, #http_req{ headers = Headers} = Req, Default) when is_atom(Name) orelse is_binary(Name) ->
	case lists:keyfind(Name, 1, Headers) of
		{Name, Value} -> {Value, Req};
		false -> {Default, Req}
	end.

%% Response API.

-spec reply(agilitycache_http_server:agilitycache_http_server_state(),
            http_status(),
            http_headers(),
            iodata(),
            #http_req{}) ->
			   {ok, #http_req{},
			    agilitycache_http_server:agilitycache_http_server_state()} | {error, any(), any()}.
reply(HttpServer, Code, Headers, Body, Req) ->
	{ok, Req0, HttpServer0} = start_reply(HttpServer, Code, Headers, iolist_size(Body), Req),
	case agilitycache_http_server:send_data(Body, HttpServer0) of
		{ok, HttpServer1} ->
			{ok, Req0, HttpServer1};
		{error, _, _} = Error ->
			Error
	end.

-spec start_reply(agilitycache_http_server:agilitycache_http_server_state(),
            http_status(),
            http_headers(),
            non_neg_integer(),
            #http_req{}) ->
			   {ok, #http_req{},
			    agilitycache_http_server:agilitycache_http_server_state()} | {error, any(), any()}.
start_reply(HttpServer, Code, Headers, Length, Req=#http_req{connection=Connection, version=Version}) ->
	MyHeaders0 = [
	              {<<"Connection">>, agilitycache_http_protocol_parser:atom_to_connection(Connection)},
	              {<<"Date">>, cowboy_clock:rfc1123()},
	              {<<"Server">>, <<"AgilityCache">>}
	             ],
	MyHeaders = case Length of
		            undefined ->
			            MyHeaders0;
		            _ when is_integer(Length)->
			            [{<<"Content-Length">>, list_to_binary(integer_to_list(Length))} | MyHeaders0]
	            end,

	Head = agilitycache_http_rep:response_head(Version, Code, Headers, MyHeaders),
	%% @todo arrumar isso pra fazer um match mais bonitinho
	%% ou passar isso pra frente
	case agilitycache_http_server:send_data(Head, HttpServer) of
		{ok, HttpServer0} ->
			{ok, Req, HttpServer0};
		{error, _, _} = Error ->
			Error
	end.

-spec request_head(#http_req{}) -> iodata().
request_head(Req) ->
	{Major, Minor} = Req#http_req.version,
	Majorb = list_to_binary(integer_to_list(Major)),
	Minorb = list_to_binary(integer_to_list(Minor)),
	Method = agilitycache_http_protocol_parser:method_to_binary(Req#http_req.method),
	Path1= Req#http_req.uri#http_uri.path,
	Qs = Req#http_req.uri#http_uri.query_string,
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

