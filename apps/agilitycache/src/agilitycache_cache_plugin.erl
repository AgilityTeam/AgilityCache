-module(agilitycache_cache_plugin).

-include("cache.hrl").

-callback name() -> binary().
-callback in_charge(#http_req{}) -> boolean().
-callback cacheable(#http_req{}) -> boolean().
-callback cacheable(#http_req{}, #http_rep{}) -> boolean().
-callback file_id(#http_req{}) -> cache_file_id().
-callback expires(#http_req{}, #http_rep{}) -> calendar:datetime().

