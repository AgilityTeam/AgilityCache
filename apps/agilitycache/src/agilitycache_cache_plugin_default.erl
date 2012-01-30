-module(agilitycache_cache_plugin_default).

-behaviour(agilitycache_cache_plugin).

-export([
		name/0,
		in_charge/1,
		cacheable/2,
		file_id/1,
		expires/3
	]).

name() ->
	<<"PluginDefault">>. % compatibilidade com os nomes do C++

in_charge(_HttpReq) ->
	true.

cacheable(_HttpReq, _HttpRep) ->
	false.

%% Nunca deve chamar isto
file_id(_HttpReq) -> 
	erlang:error(not_implemented).

%% Nem isto
expires(_DateTime, _HttpReq, _HttpRep) ->
	erlang:error(not_implemented).
