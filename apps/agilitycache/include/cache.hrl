-include("http.hrl").

-record(cached_file_info, {
    http_rep = #http_rep{} :: #http_rep{},
    age :: calendar:datetime(),
    max_age :: calendar:datetime()
  }).


-type cache_file_id() :: <<_:128>>.
-record(agilitycache_transit_file_reading, {
    id :: cache_file_id(),
    process :: pid()
  }).
-record(agilitycache_transit_file_downloading, {
    id :: cache_file_id(),
    process :: pid()
  }).

