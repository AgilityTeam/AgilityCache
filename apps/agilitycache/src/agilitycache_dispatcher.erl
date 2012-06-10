%% @doc Dispatch requests according to a hostname and path.
-module(agilitycache_dispatcher).

-export([split_host_port/1, split_host/1, split_path/1, match/2]). %% API.

-type path_tokens() :: list(binary()).
-type dispatch_rule() :: list({module(), any()}).
-type dispatch_rules() :: list(dispatch_rule()).

-export_type([path_tokens/0, dispatch_rules/0]).

-include("include/http.hrl").

%% API.
-spec split_host_port(binary()) -> {iodata(), undefined | inet:port_number()}.
split_host_port(<<>>) ->
	{<<>>, undefined};
split_host_port(Host) ->
	case binary:split(Host, <<":">>) of
		[Host] ->
			{Host, undefined};
		[Host2, Port] ->
			{Host2, list_to_integer(binary_to_list(Port))}
	end.

%% @doc Split a hostname into a list of tokens.
-spec split_host(binary())
		-> {[binary()], binary(), undefined | inet:port_number()}.
split_host(<<>>) ->
    {[], <<>>, undefined};
split_host(Host) ->
    case binary:split(Host, <<":">>) of
	[Host] ->
	    {binary:split(Host, <<".">>, [global, trim]), Host, undefined};
	[Host2, Port] ->
	    {binary:split(Host2, <<".">>, [global, trim]), Host2,
	     list_to_integer(binary_to_list(Port))}
    end.

%% @doc Split a path into a list of tokens.
-spec split_path(binary()) -> {path_tokens(), binary(), binary()}.
split_path(Path) ->
    URLDecode = fun(Bin) -> cowboy_http:urldecode(Bin, crash) end,
    cowboy_dispatcher:split_path(Path, URLDecode).

%% @doc Match hostname tokens and path tokens against dispatch rules.
%%
%% It is typically used for matching tokens for the hostname and path of
%% the request against a global dispatch rule for your listener.
%%
%% Dispatch rules are a list of <em>{Hostname, PathRules}</em> tuples, with
%% <em>PathRules</em> being a list of <em>{Path, HandlerMod, HandlerOpts}</em>.
%%
%% <em>Hostname</em> and <em>Path</em> are match rules and can be either the
%% atom <em>'_'</em>, which matches everything for a single token, the atom
%% <em>'*'</em>, which matches everything for the rest of the tokens, or a
%% list of tokens. Each token can be either a binary, the atom <em>'_'</em>,
%% the atom '...' or a named atom. A binary token must match exactly,
%% <em>'_'</em> matches everything for a single token, <em>'...'</em> matches
%% everything for the rest of the tokens and a named atom will bind the
%% corresponding token value and return it.
%%
%% The list of hostname tokens is reversed before matching. For example, if
%% we were to match "www.dev-extend.eu", we would first match "eu", then
%% "dev-extend", then "www". This means that in the context of hostnames,
%% the <em>'...'</em> atom matches properly the lower levels of the domain
%% as would be expected.
%%
%% When a result is found, this function will return the handler module and
%% options found in the dispatch list.
-spec match(#http_req{}, dispatch_rules())
	   -> {ok, module(), any()} | {error, notfound}.
match(_Req, []) ->
    {error, notfound};
match(Req, [{Handler, Opts}|Tail]) ->
    case try_match(Handler, Opts, Req) of
	false ->
	    match(Req, Tail);
	true ->
	    {ok, Handler, Opts}
    end.

%% Internal.

-spec try_match(module(), any(), #http_req{})
	       -> true | false.
try_match(Handler, Opts, Req) ->
    Handler:match(Req, Opts).

%% Tests.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

split_host_test_() ->
    %% {Host, Result}
    Tests = [
	     {<<"">>, {[], <<"">>, undefined}},
	     {<<".........">>, {[], <<".........">>, undefined}},
	     {<<"*">>, {[<<"*">>], <<"*">>, undefined}},
	     {<<"cowboy.dev-extend.eu">>,
	      {[<<"cowboy">>, <<"dev-extend">>, <<"eu">>],
	       <<"cowboy.dev-extend.eu">>, undefined}},
	     {<<"dev-extend..eu">>,
	      {[<<"dev-extend">>, <<>>, <<"eu">>],
	       <<"dev-extend..eu">>, undefined}},
	     {<<"dev-extend.eu">>,
	      {[<<"dev-extend">>, <<"eu">>], <<"dev-extend.eu">>, undefined}},
	     {<<"dev-extend.eu:8080">>,
	      {[<<"dev-extend">>, <<"eu">>], <<"dev-extend.eu">>, 8080}},
	     {<<"a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u.v.w.x.y.z">>,
	      {[<<"a">>, <<"b">>, <<"c">>, <<"d">>, <<"e">>, <<"f">>, <<"g">>,
		<<"h">>, <<"i">>, <<"j">>, <<"k">>, <<"l">>, <<"m">>, <<"n">>,
		<<"o">>, <<"p">>, <<"q">>, <<"r">>, <<"s">>, <<"t">>, <<"u">>,
		<<"v">>, <<"w">>, <<"x">>, <<"y">>, <<"z">>],
	       <<"a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u.v.w.x.y.z">>,
	       undefined}}
	    ],
    [{H, fun() -> R = split_host(H) end} || {H, R} <- Tests].

split_host_fail_test_() ->
    Tests = [
	     <<"dev-extend.eu:owns">>,
	     <<"dev-extend.eu: owns">>,
	     <<"dev-extend.eu:42fun">>,
	     <<"dev-extend.eu: 42fun">>,
	     <<"dev-extend.eu:42 fun">>,
	     <<"dev-extend.eu:fun 42">>,
	     <<"dev-extend.eu: 42">>,
	     <<":owns">>,
	     <<":42 fun">>
	    ],
    [{H, fun() -> case catch split_host(H) of
		      {'EXIT', _Reason} -> ok
		  end end} || H <- Tests].

split_path_test_() ->
    %% {Path, Result, QueryString}
    Tests = [
	     {<<"?">>, [], <<"">>, <<"">>},
	     {<<"???">>, [], <<"">>, <<"??">>},
	     {<<"/">>, [], <<"/">>, <<"">>},
	     {<<"/users">>, [<<"users">>], <<"/users">>, <<"">>},
	     {<<"/users?">>, [<<"users">>], <<"/users">>, <<"">>},
	     {<<"/users?a">>, [<<"users">>], <<"/users">>, <<"a">>},
	     {<<"/users/42/friends?a=b&c=d&e=notsure?whatever">>,
	      [<<"users">>, <<"42">>, <<"friends">>],
	      <<"/users/42/friends">>, <<"a=b&c=d&e=notsure?whatever">>},
	     {<<"/users/a+b/c%21d?e+f=g+h">>,
	      [<<"users">>, <<"a b">>, <<"c!d">>],
	      <<"/users/a+b/c%21d">>, <<"e+f=g+h">>}
	    ],
    [{P, fun() -> {R, RawP, Qs} = split_path(P) end}
     || {P, R, RawP, Qs} <- Tests].

-endif.
