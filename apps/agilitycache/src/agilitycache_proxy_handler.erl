-module(agilitycache_proxy_handler).
-behaviour(agilitycache_http_handler).
-export([init/3, match/2, handle/2, terminate/2]).

-include_lib("kernel/include/inet.hrl").
-include("include/http.hrl").

-record(state, {
	http_client :: pid()
	}).

init({tcp, http}, Req, Opts) ->
  {ok, Req, Opts}.

handle(Req=#http_req{transport=Transport}, State) ->
  {ok, HttpClientPid} = agilitycache_http_protocol_client:start_link([{http_req, Req}, {transport, Transport}]),
  {ok, Rep} = agilitycache_http_protocol_client:start_request(HttpClientPid),
  {Status, Rep2} = agilitycache_http_rep:status(Rep),
  {Headers, Rep3} = agilitycache_http_rep:headers(Rep2),
  {Length, Rep4} = agilitycache_http_rep:content_length(Rep3),
  {ok, Req2} = agilitycache_http_req:start_reply(Status, Headers, Length, Req),
  do_send_body(Req2, Rep, HttpClientPid),
  {ok, Req2#http_req{resp_state=done}, State}.

match(_Req, _Opts) ->
  true.

terminate(_Req, _State) ->
  ok.

do_send_body(Req, Rep, HttpClientPid) ->
	{ok, Data} = agilitycache_http_protocol_client:get_body(HttpClientPid),
	case iolist_size(Data) of
		0 ->
			agilitycache_http_req:send_reply(Data, Req),
			do_send_body(Req, Rep, HttpClientPid);
		_ ->
			ok
	end.
