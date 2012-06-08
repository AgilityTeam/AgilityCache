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
