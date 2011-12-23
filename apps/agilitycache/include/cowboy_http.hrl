-record(cowboy_http_req, {
	%% Transport.
	socket     = undefined :: undefined | inet:socket(),
	transport  = undefined :: undefined | module(),
	connection = keepalive :: keepalive | close,

	%% Request.
	method     = 'GET'     :: http_method(),
	version    = {1, 1}    :: http_version(),
	peer       = undefined :: undefined | {inet:ip_address(), inet:ip_port()},
	host       = undefined :: undefined | cowboy_dispatcher:tokens(),
	host_info  = undefined :: undefined | cowboy_dispatcher:tokens(),
	raw_host   = undefined :: undefined | binary(),
	port       = undefined :: undefined | inet:ip_port(),
	path       = undefined :: undefined | '*' | cowboy_dispatcher:tokens(),
	path_info  = undefined :: undefined | cowboy_dispatcher:tokens(),
	raw_path   = undefined :: undefined | binary(),
	qs_vals    = undefined :: undefined | list({binary(), binary() | true}),
	raw_qs     = undefined :: undefined | binary(),
	bindings   = undefined :: undefined | cowboy_dispatcher:bindings(),
	headers    = []        :: http_headers(),
	p_headers  = []        :: [any()], %% @todo Improve those specs.
	cookies    = undefined :: undefined | http_cookies(),
	meta       = []        :: [{atom(), any()}],

	%% Request body.
	body_state = waiting   :: waiting | done,
	buffer     = <<>>      :: binary(),

	%% Response.
	resp_state = waiting   :: locked | waiting | chunks | done,
	resp_headers = []      :: http_headers(),
	resp_body  = <<>>      :: iodata(),

	%% Functions.
	urldecode :: {fun((binary(), T) -> binary()), T}
}).
