-module(agilitycache_app).

-behaviour(application).

%% Application callbacks
-export([start/0, start/1, start/2, stop/1]).

-export([instrumentation/0, instrumentation/1]).
-export([instrument_function/2, instrument_function/3, instrument_function/4]).

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

-spec instrument_function(_,fun(() -> any())) -> any().
instrument_function(Hist, F) ->
	Before = os:timestamp(),
	Val = F(),
	After = os:timestamp(),
	folsom_metrics:notify({Hist, timer:now_diff(After, Before)}),
	Val.

-spec instrument_function(_,fun() | {atom() | tuple(),atom()},[any()]) -> any().
instrument_function(Hist, F, A) ->
	Before = os:timestamp(),
	Val = apply(F, A),
	After = os:timestamp(),
    	folsom_metrics:notify({Hist, timer:now_diff(After, Before)}),
	Val.

-spec instrument_function(_,atom() | tuple(),atom(),[any()]) -> any().
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
