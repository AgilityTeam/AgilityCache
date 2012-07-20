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

-include("http.hrl").

-record(cached_file_info, {
    http_rep = #http_rep{} :: #http_rep{},
    age :: calendar:datetime(),
    max_age :: calendar:datetime()
  }).


-type cache_file_id() :: <<_:128>>.
-record(agilitycache_transit_file_reading, {
    id :: cache_file_id(),
    process :: pid()
  }).
-record(agilitycache_transit_file_downloading, {
    id :: cache_file_id(),
    process :: pid()
  }).

