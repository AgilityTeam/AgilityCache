-module(agilitycache_date_time).
-export([parse_simple_string/1, generate_simple_string/1, convert_request_date/1, generate_rfc1123_date/1]).

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
      {ok, <<Date/binary, " ", Time/binary>>}
  catch
    error:Error ->
      {error, Error}
  end.

-spec generate_date_string(integer(), 1..12, integer()) -> binary().

generate_date_string(Year, Month, Day) ->
  BYear = list_to_binary(integer_to_list(Year)),
  BMonth = month2(Month),
  BDay = pad_int(Day),
  <<BYear/binary, "-", BMonth/binary, "-", BDay/binary>>.

-spec generate_time_string(0..23, 0..59, 0..59) -> binary().

generate_time_string(Hour, Minute, Second) ->
  BHour = pad_int(Hour),
  BMinute = pad_int(Minute),
  BSecond = pad_int(Second),
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

%% From httpd_util.erl, ported to use binaries

-spec convert_request_date(binary()) -> {ok, calendar:datetime()} | {error, any()}.

convert_request_date(<<_:3/binary, DateType:1/binary, _/binary>> = Date) ->
  Func=case DateType of
    <<",">> ->
      fun convert_rfc1123_date/1;
    <<" ">>  ->
      fun convert_ascii_date/1;
    _ ->
      fun convert_rfc850_date/1
  end,
  try
    Func(Date)
  of
    {ok, _} = Date2 ->
      Date2
  catch
    error:_Error ->
      {error, bad_date}
  end.
-spec convert_rfc850_date(<<_:32,_:_*8>>) -> {'ok',{{integer(),1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12,integer()},{integer(),integer(),integer()}}}.
convert_rfc850_date(DateStr) ->
  [_WeekDay,Date,Time,_TimeZone|_Rest] = binary:split(DateStr, <<" ">>, [global]),
    convert_rfc850_date(Date,Time).

-spec convert_rfc850_date(<<_:72>>,<<_:64>>) -> {'ok',{{integer(),1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12,integer()},{integer(),integer(),integer()}}}.
convert_rfc850_date(<<Day0:2/binary, "-", Month0:3/binary, "-", Year0:2/binary>>, <<Hour0:2/binary, ":", Minutes0:2/binary, ":", Seconds0:2/binary>>)->
    Year=list_to_integer(lists:flatten([50,48,binary_to_list(Year0)])),
    Day=list_to_integer(binary_to_list(Day0)),
    Month = month(Month0),
    Hour=list_to_integer(binary_to_list(Hour0)),
    Min=list_to_integer(binary_to_list(Minutes0)),
    Sec=list_to_integer(binary_to_list(Seconds0)),
    {ok,{{Year,Month,Day},{Hour,Min,Sec}}}.

-spec convert_ascii_date(<<_:192>>) -> {'ok',{{integer(),1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12,integer()},{integer(),integer(),integer()}}}.
convert_ascii_date(<<_:3/binary, " ", Month0:3/binary, " ", Day0:2/binary, " ", Hour0:2/binary, ":", Minutes0:2/binary, ":", Seconds0:2/binary, " ", Year0:4/binary>>)->
  Year=list_to_integer(binary_to_list(Year0)),
  Day=case Day0 of
    <<" ", Day1/binary>> ->
      list_to_integer(binary_to_list(Day1));
    _->
      list_to_integer(binary_to_list(Day0))
  end,
    Month = month(Month0),
    Hour=list_to_integer(binary_to_list(Hour0)),
    Min=list_to_integer(binary_to_list(Minutes0)),
    Sec=list_to_integer(binary_to_list(Seconds0)),
    {ok,{{Year,Month,Day},{Hour,Min,Sec}}}.

-spec convert_rfc1123_date(<<_:64,_:_*8>>) -> {'ok',{{integer(),1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12,integer()},{integer(),integer(),integer()}}}.
convert_rfc1123_date(<<_:3/binary, ", ",
                       Day0:2/binary, " ",
                       Month0:3/binary, " ",
                       Year0:4/binary, " ",
                       Hour0:2/binary, ":",
                       Minutes0:2/binary, ":",
                       Seconds0:2/binary,
                       _/binary>>) ->
  Year=list_to_integer(binary_to_list(Year0)),
  Day=list_to_integer(binary_to_list(Day0)),
  Month = month(Month0),
  Hour=list_to_integer(binary_to_list(Hour0)),
  Min=list_to_integer(binary_to_list(Minutes0)),
  Sec=list_to_integer(binary_to_list(Seconds0)),
  {ok,{{Year,Month,Day},{Hour,Min,Sec}}}.

% Wed, 15 Feb 2012 16:27:3b GMT

-spec generate_rfc1123_date(calendar:datetime()) -> binary().

generate_rfc1123_date({{Year, Month, Day} = DoW, {Hour, Minutes, Seconds}}) ->
  DayName = day(calendar:day_of_the_week(DoW)),
  BYear = list_to_binary(integer_to_list(Year)),
  BMonth = month2(Month),
  BDay = pad_int(Day),
  BHour = pad_int(Hour),
  BMinutes = pad_int(Minutes),
  BSeconds = pad_int(Seconds),
  <<DayName/binary, ", ", BDay/binary, " ", BMonth/binary, " ",
    BYear/binary, " ", BHour/binary, ":", BMinutes/binary, ":", BSeconds/binary, " GMT">>.

-spec day(1..7) -> binary().

day(1) -> <<"Mon">>;
day(2) -> <<"Tue">>;
day(3) -> <<"Wed">>;
day(4) -> <<"Thu">>;
day(5) -> <<"Fri">>;
day(6) -> <<"Sat">>;
day(7) -> <<"Sun">>.

%% From cowboy_clock.erl
-spec pad_int(0..59) -> binary().

pad_int(X) when X < 10 ->
    << $0, ($0 + X) >>;
pad_int(X) ->
    list_to_binary(integer_to_list(X)).


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
