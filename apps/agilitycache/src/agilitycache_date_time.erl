-module(agilitycache_date_time).
-export([parse_simple_string/1, generate_simple_string/1]).

-spec parse_simple_string(binary()) -> {ok, calendar:datetime()} | {error, any()}.
parse_simple_string(<<Year:4/binary, "-", Month:3/binary,   "-", Day:2/binary,
                      " ", Hour:2/binary, ":", Minutes:2/binary, ":", Seconds:2/binary>>) ->

  try
    {parse_date(Year, Month, Day),
     parse_time(Hour, Minutes, Seconds)}
  of

    {_Date, _Time}=DateTime ->
      {ok, DateTime}

  catch
    error:Error ->
      {error, Error}

  end.


-spec parse_date(binary(), binary(), binary()) -> {integer(), integer(), integer()}.
parse_date(Year, Month, Day) when is_binary(Year), is_binary(Month), is_binary(Day) ->
  {list_to_integer(binary_to_list(Year)),
   month(Month),
   list_to_integer(binary_to_list(Day))}.

-spec parse_time(binary(), binary(), binary()) -> {integer(), integer(), integer()}.
parse_time(Hour, Minute, Second) when is_binary(Hour), is_binary(Minute), is_binary(Second) ->
  {list_to_integer(binary_to_list(Hour)),
   list_to_integer(binary_to_list(Minute)),
   list_to_integer(binary_to_list(Second))}.

-spec month(binary()) -> 1..12 | no_return().
month(<<"Jan">>)  ->  1;
month(<<"Feb">>)  ->  2;
month(<<"Mar">>)  ->  3;
month(<<"Apr">>)  ->  4;
month(<<"May">>)  ->  5;
month(<<"Jun">>)  ->  6;
month(<<"Jul">>)  ->  7;
month(<<"Aug">>)  ->  8;
month(<<"Sep">>)  ->  9;
month(<<"Oct">>)  -> 10;
month(<<"Nov">>)  -> 11;
month(<<"Dec">>)  -> 12;
month(_)          -> erlang:error(invalid_month).

-spec generate_simple_string(calendar:datetime()) -> {ok, binary()} | {error, any()}.
generate_simple_string({{Year, Month, Day}, {Hour, Minute, Second}}) ->
  try {generate_date_string(Year, Month, Day),
       generate_time_string(Hour, Minute, Second) }
  of 
    {Date, Time} ->
      <<Date/binary, " ", Time/binary>>
  catch
    error:Error ->
      {error, Error}
  end.

-spec generate_date_string(integer(), 1..12, integer()) -> binary().
generate_date_string(Year, Month, Day) ->
  BYear = list_to_binary(integer_to_list(Year)),
  BMonth = month2(Month),
  BDay = list_to_binary(integer_to_list(Day)),
  <<BYear/binary, "-", BMonth/binary, "-", BDay/binary>>.

-spec generate_time_string(0..23, 0..59, 0..59) -> binary().
generate_time_string(Hour, Minute, Second) ->
  BHour = list_to_binary(integer_to_list(Hour)),
  BMinute = list_to_binary(integer_to_list(Minute)),
  BSecond = list_to_binary(integer_to_list(Second)),
  <<BHour/binary, ":", BMinute/binary, ":", BSecond/binary>>.

-spec month2(1..12) -> binary() | no_return().
month2(1)   -> <<"Jan">>;
month2(2)   -> <<"Feb">>;
month2(3)   -> <<"Mar">>;
month2(4)   -> <<"Apr">>;
month2(5)   -> <<"May">>;
month2(6)   -> <<"Jun">>;
month2(7)   -> <<"Jul">>;
month2(8)   -> <<"Aug">>;
month2(9)   -> <<"Sep">>;
month2(10)  -> <<"Oct">>;
month2(11)  -> <<"Nov">>;
month2(12)  -> <<"Dec">>;
month2(_) -> erlang:error(invalid_month).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
parse_simple_string_test_() ->
  Tests = [
      {<<"2011-Dec-25 15:23:49">>, {{2011, 12, 25}, {12, 23, 49}}}
      ],
  [{H, fun() -> R = parse_simple_string(H) end} || {H, R} <- Tests].

generate_simple_string_test_() ->
  Tests = [
      { {{2011, 12, 25}, {12, 23, 49}}, <<"2011-Dec-25 15:23:49">>}
      ],
  [{H, fun() -> R = generate_simple_string(H) end} || {H, R} <- Tests].

-endif.
