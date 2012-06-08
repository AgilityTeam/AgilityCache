-module(agilitycache_app).

-behaviour(application).

%% Application callbacks
-export([start/0, start/1, start/2, stop/1]).

-export([instrumentation/0, instrumentation/1]).
-export([instrument_function/2, instrument_function/3, instrument_function/4]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start() ->
	start(agilitycache).

start(App) ->
	case application:start(App) of
		{error, {not_started, Dep}} ->
			start(Dep),
			start(App);
		Other ->
			Other
	end.

start(_StartType, _StartArgs) ->
	agilitycache_sup:start_link().

stop(_State) ->
	ok.

instrumentation() ->
	[{X, instrumentation(X)} || X <- folsom_metrics:get_metrics()].

instrumentation(resolve_time) ->
	folsom_metrics:get_histogram_statistics(resolve_time);
instrumentation(connection_time) ->
	folsom_metrics:get_histogram_statistics(connection_time);
instrumentation(requests) ->
	folsom_metrics:get_metric_value(requests).

instrument_function(Hist, F) ->
	Before = os:timestamp(),
	Val = F(),
	After = os:timestamp(),
	folsom_metrics:notify({Hist, timer:now_diff(After, Before)}),
	Val.

instrument_function(Hist, F, A) ->
	Before = os:timestamp(),
	Val = apply(F, A),
	After = os:timestamp(),
    	folsom_metrics:notify({Hist, timer:now_diff(After, Before)}),
	Val.

instrument_function(Hist, M, F, A) ->
	Before = os:timestamp(),
	Val = apply(M, F, A),
	After = os:timestamp(),
    	folsom_metrics:notify({Hist, timer:now_diff(After, Before)}),
	Val.


%%
%% Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
