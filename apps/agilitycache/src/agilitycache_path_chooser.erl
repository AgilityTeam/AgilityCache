-module(agilitycache_path_chooser).

-export([get_best_path/1]).

-define(APPLICATION, agilitycache).

get_best_path(undefined) ->
  {error, <<"Invalid path list">>};
%% @todo Improve checks
get_best_path(Paths) ->
  case get_least_used(Paths) of
    {error, Cause} ->
      {error, Cause};
    Path ->
      {Fs, _, _} = erlang:hd(Path),
      Fs
  end.
  
get_least_used(Paths) ->
  Paths2 = [{X, TotalSize, Used} || X <- Paths, {_, TotalSize, Used} = get_path_info(proplists:get_value(path, X)) ],
  lists:keysort(3, Paths2).

get_path_info(Path) ->
  FileSystems = disksup:get_disk_data(),
  case lists:keyfind(binary_to_list(Path), 1, FileSystems) of
          false ->            
            get_path_info(lists:reverse(filename:split(Path)), FileSystems);
          {FileSystem, TotalSize, Used} ->
            {FileSystem, TotalSize, Used}
  end.

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

