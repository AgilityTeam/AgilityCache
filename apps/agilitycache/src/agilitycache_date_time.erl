-module(agilitycache_date_time).
-export([parse_simple_string/1]).

-spec parse_simple_string(binary()) -> calendar:datetime() | {error, any()}.
parse_simple_string(<<Year:4/binary, "-", Month:3/binary, "-", Day:2/binary, " ", Hour:2/binary, ":", Minutes:2/binary, ":", Seconds:2/binary>>) ->
  case month(Month) of
    {error, _Reason} = Error ->
      Error;
    Month2 ->
      Binary_to_integer = fun(X) -> list_to_integer(binary_to_list(X)) end,
      try {ok, 
          {
            {Binary_to_integer(Year), 
              Month2, 
              Binary_to_integer(Day)
            },
            {Binary_to_integer(Hour),
              Binary_to_integer(Minutes),
              Binary_to_integer(Seconds)
            }
          }
        }
    catch
      _ ->
        {error, <<"algum erro">>}
    end
  end;
parse_simple_string(_) ->
    {error, no_date}.

-spec month(binary()) -> 1..12 | {error, any()}.
month(<<"Jan">>) ->  1;
month(<<"Feb">>) ->  2;
month(<<"Mar">>) ->  3;
month(<<"Apr">>) ->  4;
month(<<"May">>) ->  5;
month(<<"Jun">>) ->  6;
month(<<"Jul">>) ->  7;
month(<<"Aug">>) ->  8;
month(<<"Sep">>) ->  9;
month(<<"Oct">>) -> 10;
month(<<"Nov">>) -> 11;
month(<<"Dec">>) -> 12;
month(_) -> {error, <<"invalid_month">>}.
