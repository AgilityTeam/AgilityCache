-module(agilitycache_cache_plugin_accuradio).
-behaviour(agilitycache_cache_plugin).

%% vimerl compile fix
-ifdef(VIMERL).
-include("../agilitycache/include/cache.hrl").
-else.
-include_lib("agilitycache/include/cache.hrl").
-endif.

-export([
         name/0,
         in_charge/1,
         cacheable/1,
         cacheable/2,
         file_id/1,
         expires/2
        ]).

-spec name() -> binary().
name() ->
	<<"AccuRadio">>.

-spec in_charge(#http_req{}) -> boolean().
in_charge(_HttpReq = #http_req{ uri=_Uri=#http_uri{domain = <<"3393.voxcdn.com">>, port = 80, path=Path }}) ->
	case binary:match(Path, [<<".m4a">>]) of
		nomatch -> false;
		_ -> true
	end;
in_charge(_) ->
	false.

-spec cacheable(#http_req{}) -> boolean().
cacheable(_HttpReq) ->
	true.

-spec cacheable(#http_req{}, #http_rep{}) -> boolean().
cacheable(_HttpReq, _HttpRep = #http_rep{status=200}) ->
	true;
cacheable(_, _) ->
	false.

-spec file_id(#http_req{}) -> cache_file_id().
file_id(_HttpReq = #http_req{ uri=_Uri=#http_uri{path = Path}}) ->
	Name = name(),
	B = <<"http://Plugin.", Name/binary, Path/binary>>,
	lager:debug("B: ~p", [B]),
	erlang:md5(B).

-spec expires(#http_req{}, #http_rep{}) -> calendar:datetime().
expires(_HttpReq, HttpRep) ->
	%% VoxCdn doesn't send expires...
	%% we estimate based on last-modified
	agilitycache_cache_plugin_utils:max_age_estimate(HttpRep).
