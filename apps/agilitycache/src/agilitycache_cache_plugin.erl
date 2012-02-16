-module(agilitycache_cache_plugin).

-export([behaviour_info/1]).

-spec behaviour_info(atom()) -> list({atom(), non_neg_integer}) | undefined.
behaviour_info(callbacks) ->
	[
		%% -spec name() -> binary().
		{name,0},
		%% -spec in_charge(#http_req{}) -> boolean().
		{in_charge, 1},
		%% -spec cacheable(#http_req{}) -> boolean().
		{cacheable, 1},
		%% -spec cacheable(#http_req{}, #http_rep{}) -> boolean().
		{cacheable, 2},
		%% -spec file_id(#http_req{}) -> binary(). [md5sum]
		{file_id, 1},
		%% -spec expires(#http_req{}, #http_rep{}) -> calendar:datetime()
		{expires, 2}
	];
behaviour_info(_Other) ->
    undefined.
