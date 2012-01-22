-include("http.hrl").

-record(cached_file_info, {
    http_rep = #http_rep{} :: #http_rep{},
    age :: calendar:datetime(),
    max_age :: calendar:datetime()
  }).


-record(cached_file, {
    id :: binary(),
    cached_file_info :: #cached_file_info{}
  }).


