-include("http.hrl").

-record(cached_file_info, {
    http_rep = #http_rep{} :: #http_rep{},
    age :: calendar:datetime(),
    max_age :: calendar:datetime()
  }).


-record(agilitycache_transit_file, {
    id :: binary(),
    status = undefined :: downloading | reading | undefined,
    concurrent_readers = 0 :: non_neg_integer()
  }).


