%% This file is part of AgilityCache, a web caching proxy.
%%
%% Copyright (C) 2011, 2012 Joaquim Pedro França Simão
%%
%% AgilityCache is free software: you can redistribute it and/or modify
%% it under the terms of the GNU Affero General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% AgilityCache is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU Affero General Public License for more details.
%%
%% You should have received a copy of the GNU Affero General Public License
%% along with this program.  If not, see <http://www.gnu.org/licenses/>.

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
