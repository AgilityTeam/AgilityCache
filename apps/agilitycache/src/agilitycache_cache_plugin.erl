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

-module(agilitycache_cache_plugin).

-include("cache.hrl").

-callback name() -> binary().
-callback in_charge(#http_req{}) -> boolean().
-callback cacheable(#http_req{}) -> boolean().
-callback cacheable(#http_req{}, #http_rep{}) -> boolean().
-callback file_id(#http_req{}) -> cache_file_id().
-callback expires(#http_req{}, #http_rep{}) -> calendar:datetime().
