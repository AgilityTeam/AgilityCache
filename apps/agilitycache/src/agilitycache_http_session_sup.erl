-module(agilitycache_http_session_sup).
-behaviour(supervisor).

-export([start_link/4, init/1, start_sup/4]).

start_link(ListenerPid, Socket, Transport, Opts) ->
	Pid = spawn_link(?MODULE, start_sup,
	                 [ListenerPid, Socket, Transport, Opts]),
	{ok, Pid}.

start_sup(ListenerPid, Socket, Transport, Opts)	->
	{ok, SupPid} = supervisor:start_link(?MODULE, []),
	{ok, SessionPid} = supervisor:start_child(SupPid,
		{agilitycache_http_session, 
			{agilitycache_http_session, start_link, [SupPid, Socket, Transport, Opts]},
		 temporary, brutal_kill, worker, [agilitycache_http_session]}),
	Transport:controlling_process(Socket, SessionPid),
	cowboy:accept_ack(ListenerPid),	
	agilitycache_http_session:protocol_loop(SessionPid),
	ok.

init([]) ->
        RestartStrategy = one_for_one,
        MaxRestarts = 0,
        MaxSecondsBetweenRestarts = 1,

        SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

        {ok, {SupFlags, []}}.

