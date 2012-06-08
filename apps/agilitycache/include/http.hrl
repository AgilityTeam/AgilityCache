%% Copyright (c) 2011, Loïc Hoguin <essen@dev-extend.eu>
%% Copyright (c) 2011, Anthony Ramine <nox@dev-extend.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

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
            port           = undefined :: undefined | inet:ip_port(),
            path           = <<"/">>   :: iodata(),
            query_string   = <<>>      :: iodata()
           }).

-record(http_req, {
            %% Request.
            method         = 'GET'     :: http_method(),
            version        = {1, 1}    :: http_version(),
            peer           = undefined :: undefined | {inet:ip_address(), inet:ip_port()},
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
            peer           = undefined :: undefined | {inet:ip_address(), inet:ip_port()},
            headers        = []        :: http_headers(),
            connection     = keepalive :: keepalive | close,
            content_length = undefined :: undefined | non_neg_integer()
           }).

