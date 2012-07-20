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

-module(agilitycache_app).

-behaviour(application).

%% Application callbacks
-export([start/0, start/1, start/2, stop/1]).

-export([instrumentation/0, instrumentation/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

-spec start() -> 'ok' | {'error',_}.
start() ->
	start(agilitycache).

-spec start(atom()) -> 'ok' | {'error',_}.
start(App) ->
	case application:start(App) of
		{error, {not_started, Dep}} ->
			start(Dep),
			start(App);
		Other ->
			Other
	end.

-spec start(_,_) -> {'error',_} | {'ok',pid()} | {'ok',pid(),_}.
start(_StartType, _StartArgs) ->
	agilitycache_sup:start_link().

-spec stop(_) -> 'ok'.
stop(_State) ->
	ok.

-spec instrumentation() -> [{_,_}].
instrumentation() ->
	[{X, instrumentation(X)} || X <- folsom_metrics:get_metrics()].

-spec instrumentation(_) -> any().
instrumentation(Metric) ->
	case folsom_metrics:get_metric_info(Metric) of
		[{Metric, Info}] ->
			case proplists:get_value(type, Info) of
				histogram ->
					folsom_metrics:get_histogram_statistics(Metric);
				_ ->
					folsom_metrics:get_metric_value(Metric)
			end;
		Error ->
			Error
	end.
