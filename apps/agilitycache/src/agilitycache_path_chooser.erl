-module(agilitycache_path_chooser).

-export([get_best_path/1]).

-spec get_best_path(list() | undefined) -> {ok, binary() | string()} | {error, any()}. 
get_best_path(undefined) ->
  {error, <<"Invalid path list">>};
%% @todo Improve checks
get_best_path(Paths) ->
  case get_least_used(Paths) of
    {error, Cause} ->
      {error, Cause};
    Path ->
      {Fs, _, _} = erlang:hd(Path),
      {ok, Fs}
  end.

-spec get_least_used(list()) -> list() | {error, any()}.
get_least_used(Paths) ->
  Paths2 = lists:map(fun(X) -> Mpath = proplists:get_value(path, X),
        {_, TotalSize, Used} = get_path_info(Mpath),
        {Mpath, TotalSize, Used} end, Paths),
  lists:keysort(3, Paths2).

-spec get_path_info(binary() | list()) -> {binary() | list(), integer(), integer()} | {error, any()}.
get_path_info(Path) when is_list(Path) ->
  get_path_info(list_to_binary(Path));
get_path_info(Path) when is_binary(Path)->
  FileSystems = disksup:get_disk_data(),
  case lists:keyfind(binary_to_list(Path), 1, FileSystems) of
    false ->            
      get_path_info(lists:reverse(filename:split(Path)), FileSystems);
    {FileSystem, TotalSize, Used} ->
      {FileSystem, TotalSize, Used}
  end.

-spec get_path_info(list(), {string(), integer(), integer()}) -> {binary() | list(), integer(), integer()} | {error, any()}.
get_path_info([], _) ->
  {error, notfound};
get_path_info([_|[]], _) ->
  {error, notfound};
get_path_info([_|Path], FileSystems) ->
  case lists:keyfind(binary_to_list(filename:join(lists:reverse(Path))), 1, FileSystems) of
    false ->
      get_path_info(Path, FileSystems);
    {FileSystem, TotalSize, Used} ->
      {FileSystem, TotalSize, Used}
  end.

%-ifdef(TEST).
%-include_lib("eunit/include/eunit.hrl").
%get_bets_path_test_() ->
%  Tests = [
%    {[[{path, <<"/home/agilitycache/var/database">>}]], <<"/home/agilitycache/var/database">>}
%  ],
%  [{H, fun() -> R = get_best_path(H) end} || {H, R} <- Tests].
%-endif.

