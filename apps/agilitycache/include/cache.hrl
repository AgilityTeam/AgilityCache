-include("http.hrl").

-record(cached_file_info, {
    http_rep = #http_rep{} :: #http_rep{},
    age :: calendar:datetime(),
    max_age :: calendar:datetime()
  }).


-type cache_file_id() :: <<_:128>>.
-record(agilitycache_transit_file, {
    id :: cache_file_id(),
    status = undefined :: downloading | reading | undefined,
    concurrent_readers = 0 :: non_neg_integer()
  }).


