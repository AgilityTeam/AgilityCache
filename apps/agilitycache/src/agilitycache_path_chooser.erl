%% This file is part of AgilityCache, a web caching proxy.
%%
%% Copyright (C) 2011, 2012 Joaquim Pedro França Simão
%%
%% AgilityCache is free software: you can redistribute it and/or modify
%% it under the terms of the GNU Affero General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% AgilityCache is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU Affero General Public License for more details.
%%
%% You should have received a copy of the GNU Affero General Public License
%% along with this program.  If not, see <http://www.gnu.org/licenses/>.

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
  NormalizedPath = filename:split(filename:absname(Path)),  
  get_path_info(NormalizedPath, FileSystems).

get_path_info(Path, [{FileSystem, _, _} = FSInfo | Tail]) ->
  NormalizedFSPath = filename:split(filename:absname(list_to_binary(FileSystem))),  
  case lists:prefix(NormalizedFSPath, Path) of
    true -> FSInfo;
    false -> get_path_info(Path, Tail)
  end.