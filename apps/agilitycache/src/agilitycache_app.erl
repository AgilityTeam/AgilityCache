-module(agilitycache_app).

-behaviour(application).

%% Application callbacks
-export([start/0, start/1, start/2, stop/1]).

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

%%
%% Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
