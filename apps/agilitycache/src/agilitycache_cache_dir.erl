-module(agilitycache_cache_dir).
-export([find_file/1, get_best_filepath/1]).
-define(APPLICATION, agilitycache).

%%-spec find_file(binary())
%% FileId is a md5sum in binary format
%% Devo aceitar mais de uma localização?
find_file(FileId) ->
  Paths = application:get_env(?APPLICATION, cache_dirs),
  SubPath = get_subpath(FileId),
  FilePaths = lists:map(fun(X) -> filename:join([X, SubPath]) end, Paths),
  FoundPaths = [FileFound || FileFound <- FilePaths, filelib:is_regular(FileFound)],
  case FoundPaths of
    [] ->
      {error, notfound};
    Paths1 ->
      erlang:hd(Paths1)
  end.


get_best_filepath(FileId) ->
  case agilitycache_path_chooser:get_best_path(application:get_env(?APPLICATION, cache_dirs)) of
    {error, Cause} ->
      {error, Cause};
    {ok, Path} ->
      filename:join([Path, get_subpath(FileId)])
  end.

get_subpath(FileId) ->
  HexFileId = list_to_binary(agilitycache_utils:hexstring(FileId)),
  filename:join([binary:at(HexFileId, 1), binary:at(HexFileId, 20), HexFileId]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
get_subpath_test_() ->
  %% FileId, Subpath
  Tests = [
    {<<144,1,80,152,60,210,79,176,214,150,63,125,40,225,127,114>>, <<"0/6/900150983cd24fb0d6963f7d28e17f72">>}
  ],
  [{H, fun() -> R = get_subpath(H) end} || {H, R} <- Tests].
-endif.

