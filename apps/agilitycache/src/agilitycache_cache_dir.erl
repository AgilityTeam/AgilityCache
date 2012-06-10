-module(agilitycache_cache_dir).
-export([find_file/1, get_best_filepath/1]).
-define(APPLICATION, agilitycache).

-include("cache.hrl").

%%-spec find_file(binary())
%% FileId is a md5sum in binary format
%% Devo aceitar mais de uma localização?
-spec find_file(cache_file_id()) -> {'error','notfound'} | {'ok',binary() | string()}.
find_file(FileId) ->
  Paths = [ proplists:get_value(path, X) || X <- agilitycache_utils:get_app_env(?APPLICATION, cache_dirs, []) ],
  lager:debug("Paths: ~p", [Paths]),
  lager:debug("FileId: ~p", [FileId]),
  SubPath = get_subpath(FileId),
  lager:debug("SubPath: ~p", [SubPath]),
  FilePaths = [filename:join([X, SubPath]) || X <- Paths],
  lager:debug("FilePaths: ~p", [FilePaths]),
  FoundPaths = [FileFound || FileFound <- FilePaths, filelib:is_regular(FileFound)],
  case FoundPaths of
    [] ->
      {error, notfound};
    Paths1 ->
      {ok, erlang:hd(Paths1)}
  end.


-spec get_best_filepath(_) -> {'error',_} | {'ok',binary() | string()}.
get_best_filepath(FileId) ->
  case agilitycache_path_chooser:get_best_path(agilitycache_utils:get_app_env(?APPLICATION, cache_dirs, [])) of
    {error, Cause} ->
      {error, Cause};
    {ok, Path} ->
      {ok, filename:join([Path, get_subpath(FileId)])}
  end.

-spec get_subpath(cache_file_id()) -> binary() | string().
get_subpath(FileId) ->
  HexFileId = agilitycache_utils:hexstring(FileId),
  filename:join([io_lib:format("~c", [binary:at(HexFileId, 1)]), io_lib:format("~c", [binary:at(HexFileId, 20)]), HexFileId]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
get_subpath_test_() ->
  %% FileId, Subpath
  Tests = [
    {<<144,1,80,152,60,210,79,176,214,150,63,125,40,225,127,114>>, <<"0/6/900150983cd24fb0d6963f7d28e17f72">>}
  ],
  [{H, fun() -> R = get_subpath(H) end} || {H, R} <- Tests].
-endif.

