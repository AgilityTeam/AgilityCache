-module(agilitycache_cache_plugin_imgur).
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
	<<"Imgur">>.

-spec in_charge(#http_req{}) -> boolean().
in_charge(_HttpReq = #http_req{ uri=_Uri=#http_uri{domain = <<"i.imgur.com">>, port = 80 }}) ->
	true;
in_charge(_) ->
	false.

-spec cacheable(#http_req{}) -> boolean().
cacheable(_HttpReq) ->
	true.

-spec cacheable(#http_req{}, #http_rep{}) -> boolean().
cacheable(_HttpReq, _HttpRep) ->
	true.

-spec file_id(#http_req{}) -> cache_file_id().
file_id(_HttpReq = #http_req{ uri=_Uri=#http_uri{path = RawPath, port = Port }}) ->
	%%"http://Plugin." + name() + "/" + request.cannonical_url;
	Name = name(),
	BinaryPort = list_to_binary(integer_to_list(Port)),
	File = filename:rootname(RawPath), % remove extensão
	%% XXX: Put raw_qs?
	B = <<"http://Plugin.", Name/binary, ":", BinaryPort/binary, File/binary>>,
	lager:debug("B: ~p", [B]),
	erlang:md5(B).

-spec expires(#http_req{}, #http_rep{}) -> calendar:datetime().
expires(_HttpReq, HttpRep) ->
	agilitycache_cache_plugin_utils:parse_max_age(HttpRep).
