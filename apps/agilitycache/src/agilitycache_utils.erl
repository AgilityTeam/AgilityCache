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

-module(agilitycache_utils).
-export([get_app_env/2, get_app_env/3, hexstring/1]).

%% @equiv header(agilitycache, Key, Default)
-spec get_app_env(atom(), Default::any()) -> Default::any().

get_app_env(Key, Default) ->
    get_app_env(agilitycache, Key, Default).

-spec get_app_env(atom(), any(), any()) -> any().

get_app_env(App, Key, Default) ->
    case application:get_env(App, Key) of
        undefined ->
            Default;
        {ok, undefined} ->
            Default;
        {ok, Value} ->
            Value
    end.

-spec hexstring(binary()) -> binary().

hexstring(<<X:128/big-unsigned-integer>>) ->
    list_to_binary(lists:flatten(io_lib:format("~32.16.0B", [X]))).
