-module(agilitycache_http_req_conversor).

-export([req_to_cowboy/3, req_to_agilitycache/1]).

-include("include/http.hrl").
-include("include/cowboy_http.hrl").

%-spec req_to_cowboy(undefined | module(), undefined | inet:socket(), #http_req{}) -> #cowboy_http_req{}.
req_to_cowboy(Transport, Socket, #http_req{
    method     = Method,
    version    = Version,
    peer       = Peer,
    host       = Host,
    host_info  = Host_info,
    raw_host   = Raw_host,
    port       = Port,
    path       = Path,
    path_info  = Path_info,
    raw_path   = Raw_path,
    qs_vals    = Qs_vals,
    raw_qs     = Raw_qs,
    bindings   = Bindings,
    headers    = Headers,
    cookies    = Cookies,
    connection = Connection,

      %% Request body.
    body_state = Body_state,

      %% Response.
    resp_state = Resp_state
    }
    ) ->
    {
    http_req,
    %% Transport.
    %%socket      = 
    Socket,
    %%transport   = 
    Transport,
    %%connection  = 
    Connection,

    %% Request.
    %%method      = 
    Method,
    %%version     = 
    Version,
    %%peer        = 
    Peer,
    %%host        = 
    Host,
    %%host_info   = 
    Host_info,
    %%raw_host    = 
    Raw_host,
    %%port        = 
    Port,
    %%path        = 
    Path,
    %%path_info   = 
    Path_info,
    %%raw_path    = 
    Raw_path,
    %%qs_vals     = 
    Qs_vals,
    %%raw_qs      = 
    Raw_qs,
    %%bindings    = 
    Bindings,
    %%headers     = 
    Headers,
    %%p_headers   = 
    [],
    %%cookies     = 
    Cookies,
    %%meta        = 
    [],

    %% Request body.
    %%body_state  = 
    Body_state,
    %%buffer      = 
    <<>>,

    %% Response.
    %%resp_state  = 
    Resp_state,
    %%resp_headers  = 
    [],
    %%resp_body   = 
    <<>>,

    %% Functions.
    %%urldecode   = 
    {fun cowboy_http:urldecode/2, crash} 

  }.

%-spec req_to_agilitycache(#cowboy_http_req{}) -> #http_req{}.
req_to_agilitycache({ %% cowboy http_req
    http_req,
    %% Transport.
    %%socket      = 
    _Socket,
    %%transport   = 
    _Transport,
    %%connection  = 
    Connection,

    %% Request.
    %%method      = 
    Method,
    %%version     = 
    Version,
    %%peer        = 
    Peer,
    %%host        = 
    Host,
    %%host_info   = 
    Host_info,
    %%raw_host    = 
    Raw_host,
    %%port        = 
    Port,
    %%path        = 
    Path,
    %%path_info   = 
    Path_info,
    %%raw_path    = 
    Raw_path,
    %%qs_vals     = 
    Qs_vals,
    %%raw_qs      = 
    Raw_qs,
    %%bindings    = 
    Bindings,
    %%headers     = 
    Headers,
    %%p_headers   = 
    _,
    %%cookies     = 
    Cookies,
    %%meta        = 
    _,

    %% Request body.
    %%body_state  = 
    Body_state,
    %%buffer      = 
    _,

    %% Response.
    %%resp_state  = 
    Resp_state,
    %%resp_headers  = 
    _,
    %%resp_body   = 
    _,

    %% Functions.
    %%urldecode   = 
    _

  }) ->
  #http_req{
    method     = Method,
    version    = Version,
    peer       = Peer,
    host       = Host,
    host_info  = Host_info,
    raw_host   = Raw_host,
    port       = Port,
    path       = Path,
    path_info  = Path_info,
    raw_path   = Raw_path,
    qs_vals    = Qs_vals,
    raw_qs     = Raw_qs,
    bindings   = Bindings,
    headers    = Headers,
    cookies    = Cookies,
    connection = Connection,

      %% Request body.
    body_state = Body_state,

      %% Response.
    resp_state = Resp_state
  }.
