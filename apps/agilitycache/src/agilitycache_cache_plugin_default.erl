-module(agilitycache_cache_plugin_default).

-behaviour(agilitycache_cache_plugin).

-export([
		name/0,
		in_charge/1,
		cacheable/1,
		cacheable/2,
		file_id/1,
		expires/2
	]).

-include("cache.hrl").

-spec name() -> binary().
name() ->
	<<"PluginDefault">>. % compatibilidade com os nomes do C++

-spec in_charge(#http_req{}) -> boolean().
in_charge(_HttpReq) ->
	true.

-spec cacheable(#http_req{}) -> boolean().
cacheable(_HttpReq) ->
	false.

-spec cacheable(#http_req{}, #http_rep{}) -> boolean().
cacheable(_HttpReq, _HttpRep) ->
  erlang:error(not_implemented).

%% Nunca deve chamar isto
-spec file_id(#http_req{}) -> cache_file_id().
file_id(_HttpReq) ->
	erlang:error(not_implemented).

%% Nem isto
-spec expires(#http_req{}, #http_rep{}) -> calendar:datetime().
expires(_HttpReq, _HttpRep) ->
	erlang:error(not_implemented).
