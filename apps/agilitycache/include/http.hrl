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
%%
%% Based on the original http.hrl from Cowboy Project, with the
%% following copyright:
%% Copyright (c) 2011, Loïc Hoguin <essen@ninenines.eu>
%% Copyright (c) 2011, Anthony Ramine <nox@dev-extend.eu>

-type http_method()  :: 'OPTIONS' | 'GET' | 'HEAD'
                      | 'POST' | 'PUT' | 'DELETE' | 'TRACE' | binary().
-type http_version() :: {Major::non_neg_integer(), Minor::non_neg_integer()}.
-type http_header()  :: 'Cache-Control' | 'Connection' | 'Date' | 'Pragma'
                      | 'Transfer-Encoding' | 'Upgrade' | 'Via' | 'Accept' | 'Accept-Charset'
                      | 'Accept-Encoding' | 'Accept-Language' | 'Authorization' | 'From' | 'Host'
                      | 'If-Modified-Since' | 'If-Match' | 'If-None-Match' | 'If-Range'
                      | 'If-Unmodified-Since' | 'Max-Forwards' | 'Proxy-Authorization' | 'Range'
                      | 'Referer' | 'User-Agent' | 'Age' | 'Location' | 'Proxy-Authenticate'
                      | 'Public' | 'Retry-After' | 'Server' | 'Vary' | 'Warning'
                      | 'Www-Authenticate' | 'Allow' | 'Content-Base' | 'Content-Encoding'
                      | 'Content-Language' | 'Content-Length' | 'Content-Location'
                      | 'Content-Md5' | 'Content-Range' | 'Content-Type' | 'Etag'
                      | 'Expires' | 'Last-Modified' | 'Accept-Ranges' | 'Set-Cookie'
                      | 'Set-Cookie2' | 'X-Forwarded-For' | 'Cookie' | 'Keep-Alive'
                      | 'Proxy-Connection' | binary().
-type http_headers() :: list({http_header(), iodata()}).
-type http_status()  :: non_neg_integer() | binary().

-record(http_uri, {
            domain         = undefined :: undefined | binary(),
            port           = undefined :: undefined | inet:port_number(),
            path           = <<"/">>   :: iodata(),
            query_string   = <<>>      :: iodata()
           }).

-record(http_req, {
            %% Request.
            method         = 'GET'     :: http_method(),
            version        = {1, 1}    :: http_version(),
            peer           = undefined :: undefined | {inet:ip_address(), inet:port_number()},
            uri            = undefined :: undefined | #http_uri{},
            headers        = []        :: http_headers(),
            connection     = keepalive :: keepalive | close,
            content_length = undefined :: undefined | invalid | non_neg_integer()
           }).

-record(http_rep, {
            %% Request.
            status         = 200       :: http_status(),
            version        = {1, 1}    :: http_version(),
            string         = <<>>      :: iodata(),
            peer           = undefined :: undefined | {inet:ip_address(), inet:port_number()},
            headers        = []        :: http_headers(),
            connection     = keepalive :: keepalive | close,
            content_length = undefined :: undefined | non_neg_integer()
           }).
