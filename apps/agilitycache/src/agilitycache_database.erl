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

-module(agilitycache_database).

-include("cache.hrl").

-export([read_cached_file_info/3,
         write_cached_file_info/3,
         read_preliminar_info/2,
         read_remaining_info/2,
         write_info/2
        ]).

                                                %-compile(export_all).
-spec read_preliminar_info(binary(), #cached_file_info{}) -> {ok, #cached_file_info{}} | {error, any()}.
read_preliminar_info(FileId, CachedFileInfo) ->
    try
        {ok, CachedFileInfo0} = read_cached_file_info(FileId, <<"age">>, CachedFileInfo),
        {ok, _CachedFileInfo1} = read_cached_file_info(FileId, <<"max_age">>, CachedFileInfo0)
    of
        {ok, _} = Rtr ->
            Rtr
    catch
        error:Error ->
            {error, Error}
    end.

%% Assumo que já leu o preliminar info
-spec read_remaining_info(_,_) -> {'error',_} | {'ok',_}.
read_remaining_info(FileId, CachedFileInfo) ->
    try
        {ok, _CachedFileInfo0} = read_cached_file_info(FileId, <<"headers">>, CachedFileInfo)
    of
        {ok, _} = Rtr ->
            Rtr
    catch
        error:Error ->
            {error, Error}
    end.

-spec read_cached_file_info(cache_file_id(),_,_) -> {'error',atom()} | {'ok',_}.
read_cached_file_info(FileId, Info, CachedFileInfo) ->
    case find_file(FileId, Info) of
        {error, _} = Error ->
            Error;
        {ok, Path} ->
            case file:read_file(Path) of
                {ok, Data} ->
                    {ok, _} = parse_data(Info, Data, CachedFileInfo);
                {error, _ } = Error0 ->
                    Error0
            end
    end.
-spec write_cached_file_info(cache_file_id(),_,#cached_file_info{}) -> 'ok' | {'error',atom()}.
write_cached_file_info(FileId, Info, CachedFileInfo) ->
    Path = case find_file(FileId, Info) of
               {ok, Path1} ->
                   Path1;
               {error, _} ->
                   Paths = agilitycache_utils:get_app_env(database, undefined),
                   {ok, BestPath} = agilitycache_path_chooser:get_best_path(Paths),
                   SubPath = get_subpath(FileId),
                   filename:join([BestPath, SubPath, Info])
           end,
    lager:debug("Path: ~p", [Path]),
    filelib:ensure_dir(Path),
    Data = generate_data(Info, CachedFileInfo),
    case file:write_file(Path, Data) of
        {error, _} = Error0 ->
            Error0;
        ok ->
            ok
    end.

-spec write_info(cache_file_id(),#cached_file_info{}) -> 'ok'.
write_info(FileId, CachedFileInfo) ->
    ok = write_cached_file_info(FileId, <<"headers">>, CachedFileInfo),
    ok = write_cached_file_info(FileId, <<"status_code">>, CachedFileInfo),
    ok = write_cached_file_info(FileId, <<"max_age">>, CachedFileInfo),
    ok = write_cached_file_info(FileId, <<"age">>, CachedFileInfo),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec generate_data(_,#cached_file_info{}) -> binary() | [[binary() | maybe_improper_list(any(),binary() | []),...]] | non_neg_integer().
generate_data(<<"headers">>, #cached_file_info { http_rep = #http_rep { headers = Headers } }) ->
    lager:debug("Headers: ~p", [Headers]),
    Headers0 = [begin
                    BKey = agilitycache_http_protocol_parser:header_to_binary(Key),
                    [ BKey, ": ", Value, "\r\n" ]
                end || {Key, Value} <- Headers],
    lager:debug("Headers0: ~p", [Headers0]),
    Headers0;

generate_data(<<"status_code">>, #cached_file_info { http_rep = #http_rep { status = Status } })
  when is_integer(Status) ->
    lager:debug("Status: ~p", [Status]),
    list_to_binary(integer_to_list(Status));
generate_data(<<"status_code">>, #cached_file_info { http_rep = #http_rep { status = Status } }) ->
    lager:debug("Status: ~p", [Status]),
    Status;

generate_data(<<"max_age">>, #cached_file_info { max_age = MaxAge } ) ->
    {ok, MaxAge0} = agilitycache_date_time:generate_simple_string(MaxAge),
    MaxAge0;

generate_data(<<"age">>, #cached_file_info { age = Age } ) ->
    {ok, Age0} = agilitycache_date_time:generate_simple_string(Age),
    Age0.

-spec decode_headers(binary(),_) -> {'error',_} | {'ok',_}.
decode_headers(Data, CachedFileInfo) ->
    case erlang:decode_packet(httph_bin, Data, []) of
        {ok, Header, Rest} ->
            parse_headers(Header, CachedFileInfo, Rest);
        Error ->
            {error, Error}
    end.

-spec parse_data(<<_:24,_:_*32>>,binary(),_) -> {'error',_} | {'ok',_}.
parse_data(<<"headers">>, Data, CachedFileInfo) ->
    decode_headers(<<Data/binary, "\r\n">>, CachedFileInfo);

parse_data(<<"status_code">>, Data, CachedFileInfo = #cached_file_info { http_rep = Rep }) ->
    try list_to_integer(binary_to_list(Data)) of
        Status ->
            {ok, CachedFileInfo#cached_file_info{ http_rep = Rep#http_rep{ status = Status }}}
    catch
        error:_ ->
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
-spec find_file(cache_file_id(),_) -> {'error','notfound'} | {'ok',binary() | string()}.
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
            {ok, erlang:hd(FoundPaths)}
    end.

-spec get_subpath(cache_file_id()) -> binary() | string().
get_subpath(FileId) ->
    HexFileId = agilitycache_utils:hexstring(FileId),
    filename:join([io_lib:format("~c", [binary:at(HexFileId, 1)]), io_lib:format("~c", [binary:at(HexFileId, 20)]), HexFileId]).

%% Desabilita keepalive
-spec parse_headers('http_eoh' | {'http_error',binary() | string()} | {'http_header',integer(),atom() | binary(),_,binary() | string()},_,binary())
                   -> {error, _} | {'ok',_}.
parse_headers({http_header, _I, 'Connection', _R, _Connection}, CachedFileInfo = #cached_file_info{ http_rep = Rep }, Rest) ->
    ConnAtom = close,
    decode_headers(Rest, CachedFileInfo#cached_file_info{ http_rep =
                                                              Rep#http_rep{connection=ConnAtom,
                                                                           headers=[{'Connection', <<"close">>}|Rep#http_rep.headers]}});
parse_headers({http_header, _I, Field, _R, Value}, CachedFileInfo = #cached_file_info{ http_rep = Rep }, Rest) ->
    Field2 = agilitycache_http_protocol_parser:format_header(Field),
    Rep2 = Rep#http_rep{headers=[{Field2, Value}|Rep#http_rep.headers]},
    decode_headers(Rest, CachedFileInfo#cached_file_info { http_rep = Rep2 });
parse_headers(http_eoh, CachedFileInfo, _Rest) ->
    %% Ok, terminar aqui, e esperar envio!
    {ok, CachedFileInfo};
parse_headers({http_error, _Bin}, _CachedFileInfo, _Rest) ->
    {error, <<"Erro parse headers">>}.


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
