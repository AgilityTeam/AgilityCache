-module(agilitycache_cache_plugin_utils).

-export([
         parse_max_age/1,
         parse_last_modified/1,
         param_val/2,
         param_val/3]).

-ifdef(VIMERL).
-include("../agilitycache/include/http.hrl").
-else.
-include_lib("agilitycache/include/http.hrl").
-endif.

-spec parse_max_age(#http_rep{}) -> calendar:datetime().
parse_max_age(HttpRep) ->
	calendar:gregorian_seconds_to_datetime(max(calendar:datetime_to_gregorian_seconds(parse_cache_control(HttpRep)),
	                                           calendar:datetime_to_gregorian_seconds(parse_expires(HttpRep)))).

%% @todo usar s-maxage também
-spec parse_cache_control(#http_rep{}) -> calendar:datetime().
parse_cache_control(HttpRep) ->
	lager:debug("HttpRep: ~p", [HttpRep]),
	{CacheControl, _} = agilitycache_http_rep:header('Cache-Control', HttpRep, <<>>),
	CacheControlAge = case param_val(CacheControl, <<"max-age">>, <<"0">>) of
		                  true -> 0;
		                  <<"0">> -> 0;
		                  X ->
			                  list_to_integer(binary_to_list(X))
	                  end,
	calendar:gregorian_seconds_to_datetime(
	  calendar:datetime_to_gregorian_seconds(calendar:universal_time()) + CacheControlAge).

-spec parse_expires(#http_rep{}) -> calendar:datetime().
parse_expires(HttpRep) ->
	case agilitycache_http_rep:header('Expires', HttpRep) of
		{undefined, _} ->
			lager:debug("Expires undefined"),
			calendar:universal_time();
		{Expires, _} ->
			case agilitycache_date_time:convert_request_date(Expires) of
				{ok, Date0} ->
					Date0;
				{error, _} ->
					lager:debug("Expires invalid: ~p", [Expires]),
					calendar:universal_time()
			end
	end.

-spec parse_last_modified(#http_rep{}) -> calendar:datetime().
parse_last_modified(HttpRep) ->
	case agilitycache_http_rep:header('Last-Modified', HttpRep) of
		{undefined, _} ->
			lager:debug("Last-Modified undefined"),
			calendar:universal_time();
		{LastModified, _} ->
			case agilitycache_date_time:convert_request_date(LastModified) of
				{ok, Date0} ->
					Date0;
				{error, _} ->
					lager:debug("Last-Modified invalid: ~p", [LastModified]),
					calendar:universal_time()
			end
	end.

%% @equiv param_val(Name, Req, undefined)
-spec param_val(binary(), binary())
               -> binary() | true | undefined.
param_val(Str, Name) ->
	param_val(Str, Name, undefined).

%% @doc Return the query string value for the given key, or a default if
%% missing.
-spec param_val(binary(), binary(), Default)
               -> binary() | true | Default when Default::any().
param_val(Str, Name, Default) ->
	Params = parse_params(Str),
	case lists:keyfind(Name, 1, Params) of
		{Name, Value} -> Value;
		false -> Default
	end.

-spec parse_params(binary()) -> list({binary(), binary() | true}).
parse_params(<<>>) ->
	[];
parse_params(Str) ->
	lager:debug("Str: ~p", [Str]),
	Tokens = binary:split(Str, [<<" ">>, <<",">>, <<";">>], [global, trim]),
	[case binary:split(Token, <<"=">>) of
		 [Token] -> {Token, true};
		 [Name, Value] -> {Name, Value}
	 end || Token <- Tokens, Token =/= <<>>].
