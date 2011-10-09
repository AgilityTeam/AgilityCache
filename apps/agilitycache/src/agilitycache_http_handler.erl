%% @doc Handler for HTTP requests.
%%
%% HTTP handlers must implement three callbacks: <em>init/3</em>,
%% <em>handle/2</em> and <em>terminate/2</em>, called one after another in
%% that order.
%%
%% <em>init/3</em> is meant for initialization. It receives information about
%% the transport and protocol used, along with the handler options from the
%% dispatch list, and allows you to upgrade the protocol if needed. You can
%% define a request-wide state here.
%%
%% <em>handle/2</em> is meant for handling the request. It receives the
%% request and the state previously defined.
%%
%% <em>match/2</em> is meant for check if handler is capable of handling
%% the request.
%%
%% <em>terminate/2</em> is meant for cleaning up. It also receives the
%% request and the state previously defined.
%%
%% You do not have to read the request body or even send a reply if you do
%% not need to. Cowboy will properly handle these cases and clean-up afterwards.
%% In doubt it'll simply close the connection.
%%
%% Note that when upgrading the connection to WebSocket you do not need to
%% define the <em>handle/2</em> and <em>terminate/2</em> callbacks.
-module(agilitycache_http_handler).

-export([behaviour_info/1]).

%% @todo Module:upgrade(ListenerPid, Handler, Opts, Req)
%% @private
-spec behaviour_info(_)
	-> undefined | [{match, 2} | {handle, 2} | {init, 3} | {terminate, 2}, ...].
behaviour_info(callbacks) ->
	[{match,2} ,{init, 3}, {handle, 2}, {terminate, 2}];
behaviour_info(_Other) ->
	undefined.

