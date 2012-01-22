-module(agilitycache_database).

-include("include/cache.hrl").

-export([read_cached_file_info/3,
    write_cached_file_info/3]).

-compile(export_all).

read_preliminar_info(FileId, CachedFileInfo) ->
  try
  {ok, CachedFileInfo0} = read_cached_file_info(FileId, <<"age">>, CachedFileInfo),
  {ok, CachedFileInfo1} = read_cached_file_info(FileId, <<"max_age">>, CachedFileInfo0),
  {ok, CachedFileInfo1}
  catch
    Reason ->
      {error, Reason}
  end.

%% Assumo que já leu o preliminar info
read_remaining_info(FileId, CachedFileInfo) ->
  try
  {ok, CachedFileInfo0} = read_cached_file_info(FileId, <<"headers">>, CachedFileInfo),
  {ok, CachedFileInfo0}
  catch
    Reason ->
      {error, Reason}
  end.

read_cached_file_info(FileId, Info, CachedFileInfo) ->
  case find_file(FileId, Info) of
    {error, _} = Error ->
      Error;
    Path ->
      case file:read_file(Path) of
        {ok, Data} ->
          {ok, _} = parse_data(Info, Data, CachedFileInfo);
        {error, _ } = Error0 ->
            Error0
        end
    end.
write_cached_file_info(_FileId, _Info, _CachedFileInfo) ->
  %% Escrever, etc
  ok.
%%%===================================================================
%%% Internal functions
%%%===================================================================

decode_headers(Data, CachedFileInfo) ->
  case erlang:decode_packet(httph_bin, Data, []) of
    {ok, Header, Rest} ->
        parse_headers(Header, CachedFileInfo, Rest);
    Error ->
        {error, Error}
    end.

parse_data(<<"headers">>, Data, CachedFileInfo) ->
 decode_headers(<<Data/binary, "\r\n">>, CachedFileInfo);

parse_data(<<"status_code">>, Data, CachedFileInfo = #cached_file_info { http_rep = Rep }) ->
  Binary_to_integer = fun(X) -> list_to_integer(binary_to_list(X)) end,
  try Binary_to_integer(Data) of
    Status ->
      {ok, CachedFileInfo#cached_file_info{ http_rep = Rep#http_rep{ status = Status }}}
  catch
    _:_ ->
      {error, <<"algum erro">>}
  end;
parse_data(<<"max_age">>, Data, CachedFileInfo) ->
  case agilitycache_date_time:parse_simple_string(Data) of
    {error, _} = Error ->
      Error;
    {ok, DateTime} ->
      {ok, CachedFileInfo#cached_file_info{ max_age = DateTime }}
  end;

parse_data(<<"age">>, Data, CachedFileInfo) ->
  case agilitycache_date_time:parse_simple_string(Data) of
    {error, _} = Error ->
      Error;
    {ok, DateTime} ->
      {ok, CachedFileInfo#cached_file_info{ age = DateTime }}
  end.

%%-spec find_file(binary(), binary())
%% FileId is a md5sum in binary format
%% Devo aceitar mais de uma localização?
find_file(FileId, Extension) ->
  Paths1 = agilitycache_utils:get_app_env(database, undefined),
  Paths2 = lists:map(fun(X) -> proplists:get_value(path, X) end, Paths1),
  SubPath = get_subpath(FileId),
  FilePaths = lists:map(fun(X) -> filename:join([X, SubPath, Extension]) end, Paths2),
  FoundPaths = [FileFound || FileFound <- FilePaths, filelib:is_regular(FileFound)],
  case FoundPaths of 
    [] ->
      {error, notfound};
    _ ->
      erlang:hd(FoundPaths)
  end.

get_subpath(FileId) ->
  HexFileId = list_to_binary(hexstring(FileId)),
  filename:join([io_lib:format("~c", [binary:at(HexFileId, 1)]), io_lib:format("~c", [binary:at(HexFileId, 20)]), HexFileId]).

hexstring(<<X:128/big-unsigned-integer>>) ->
  lists:flatten(io_lib:format("~32.16.0B", [X])).

parse_headers({http_header, _I, Field, _R, Value}, CachedFileInfo = #cached_file_info{ http_rep = Rep }, Rest) ->
    Field2 = agilitycache_http_protocol_parser:format_header(Field),
    Rep2 = Rep#http_rep{headers=[{Field2, Value}|Rep#http_rep.headers]},
    decode_headers(Rest, CachedFileInfo#cached_file_info { http_rep = Rep2 });
parse_headers(http_eoh, CachedFileInfo, _Rest) ->
  %% Ok, terminar aqui, e esperar envio!
  {ok, CachedFileInfo};
parse_headers({http_error, _Bin}, _CachedFileInfo, _Rest) ->
  {error, <<"Erro parse headers">>}.


%test() ->
%  {ok, CachedFileInfo0} = agilitycache_database:read_preliminar_info(<<0,1,14,111,22,119,244,179,193,35,255,170,217,199,66,122>>, #cached_file_info{}),
%  agilitycache_database:read_remaining_info(<<0,1,14,111,22,119,244,179,193,35,255,170,217,199,66,122>>, CachedFileInfo0).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
get_subpath_test_() ->
  %% FileId, Subpath
  Tests = [
    {<<43,87,61,146,28,153,56,102,46,185,70,221,175,97,55,123>>, <<"B/4/2B573D921C9938662EB946DDAF61377B">>},
    {<<0,16,84,246,205,210,177,250,245,54,169,8,245,163,25,203>>, <<"0/A/001054F6CDD2B1FAF536A908F5A319CB">>}
  ],
  [{H, fun() -> R = get_subpath(H) end} || {H, R} <- Tests].
-endif.

