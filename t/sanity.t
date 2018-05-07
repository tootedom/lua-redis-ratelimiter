# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);
use Test::Nginx::Socket 'no_plan';

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;/usr/local/openresty/lualib/resty/?.lua;;";
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
$ENV{TEST_NGINX_REDIS_PORT} ||= 6379;

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: limit req
--- http_config eval
"
$::HttpConfig
lua_shared_dict ratelimit_circuit_breaker 1m;
"
--- config
    location /a {
        rewrite_by_lua '
            local ratelimit = require "resty.greencheek.redis.ratelimiter.limiter"
            local zone = "test1_" .. ngx.worker.pid()
            local lim, _ = ratelimit.new(zone, "2r/m")
            if not lim then
                return ngx.exit(500)
            end
            local ratelimited, err = lim:is_rate_limited(ngx.var.remote_addr,ngx.req.start_time())
            if ratelimited then
                return ngx.exit(503)
            end
        ';
        echo Logged in;
    }
    location /c {
        rewrite_by_lua '
            local ratelimit = require "resty.greencheek.redis.ratelimiter.limiter"
            local zone = "test1.2_" .. ngx.worker.pid()
            local lim, _ = ratelimit.new(zone, "2r/s")
            if not lim then
                return ngx.exit(500)
            end
            local ratelimited, err = lim:is_rate_limited(ngx.var.remote_addr,ngx.req.start_time())
            if ratelimited then
                return ngx.exit(503)
            end
        ';
        echo Logged in;
    }
    location /b {
        content_by_lua '
            for i = 0, 3 do
                local res = ngx.location.capture("/a")
                ngx.say("#0", i, ": ", res.status)
                ngx.sleep(0.2)
            end
            ngx.sleep(20.0)
            ngx.say()
            for i = 0, 9 do
                local res = ngx.location.capture("/c")
                ngx.say("#1", i, ": ", res.status)
                ngx.sleep(0.6)
            end
        ';
    }
--- request
GET /b
--- response_body
#00: 200
#01: 200
#02: 503
#03: 503

#10: 200
#11: 200
#12: 200
#13: 200
#14: 200
#15: 200
#16: 200
#17: 200
#18: 200
#19: 200
--- no_error_log
[error]
[warn]
--- timeout: 600


=== TEST 2: limit req with different key
--- http_config eval
"
$::HttpConfig
lua_shared_dict ratelimit_circuit_breaker 1m;
"
--- config
    location /a {
        rewrite_by_lua '
            local ratelimit = require "resty.greencheek.redis.ratelimiter.limiter"
            local zone = "test2_" .. ngx.worker.pid()
            local method = ngx.req.get_method()
            local lim, _ = ratelimit.new(zone, "2r/m")
            if not lim then
                return ngx.exit(500)
            end
            local ratelimited, err = lim:is_rate_limited(method,ngx.req.start_time())
            if ratelimited then
                return ngx.exit(503)
            end
        ';
        echo Logged in;
    }
    location /b {
        content_by_lua '
            for i = 0, 2 do
                local res = ngx.location.capture("/a")
                ngx.say("#0", i, ": ", res.status)
                ngx.sleep(0.1)
            end
            ngx.say()
            for i = 0, 1 do
                local res = ngx.location.capture("/a",
                                 { method = ngx.HTTP_HEAD })
                ngx.say("#1", i, ": ", res.status)
                ngx.sleep(0.6)
            end
            ngx.sleep(0.6)
            ngx.say()
            for i = 0, 1 do
                local res = ngx.location.capture("/a",{ method = ngx.HTTP_PUT })
                ngx.say("#2", i, ": ", res.status)
                ngx.sleep(0.6)
            end
        ';
    }
--- request
GET /b
--- timeout: 200
--- response_body
#00: 200
#01: 200
#02: 503

#10: 200
#11: 200

#20: 200
#21: 200
--- no_error_log
[error]
[warn]


=== TEST 3: incorrect redis connection details
--- http_config eval
"
$::HttpConfig
lua_shared_dict ratelimit_circuit_breaker 1m;
"
--- config
    location /t {
        rewrite_by_lua '
            local ratelimit = require "resty.greencheek.redis.ratelimiter.limiter"
            local zone = "test3_" .. ngx.worker.pid()
            local red = { host = "127.0.0.1", port = 6388 }
            local lim, _ = ratelimit.new(zone, "2r/s", red)
            if not lim then
                return ngx.exit(500)
            end
            local ratelimited = lim:is_rate_limited("foo",ngx.req.start_time())
            if delay then
                return ngx.exit(429)
            end
        ';
        echo "ok";
    }
--- request
GET /t
--- timeout: 10
--- response_body
ok
--- error_log
failed_connecting_to_redis


=== TEST 4: limit req with different dicts
--- http_config eval
"
$::HttpConfig

lua_shared_dict ratelimit_circuit_breaker 1m;
lua_shared_dict login_ratelimit_circuit_breaker 1m;
lua_shared_dict filter_ratelimit_circuit_breaker 1m;

"
--- config
    location /login {
        rewrite_by_lua '
            local ratelimit = require "resty.greencheek.redis.ratelimiter.limiter"
            local red = { circuit_breaker_dict_name = "login_ratelimit_circuit_breaker" }
            local zone = "login"
            local method = ngx.req.get_method()

            local lim, _ = ratelimit.new(zone, "2r/m",red)
            if not lim then
                return ngx.exit(500)
            end

            local ratelimited, err = lim:is_rate_limited(method,ngx.req.start_time())

            if ratelimited then
                return ngx.exit(503)
            end
        ';

        echo Logged in;
    }

    location /filter {
        rewrite_by_lua '
            local ratelimit = require "resty.greencheek.redis.ratelimiter.limiter"
            local red = { circuit_breaker_dict_name = "filter_ratelimit_circuit_breaker" }
            local zone = "login"
            local method = ngx.req.get_method()

            local lim, _ = ratelimit.new(zone, "2r/m", red)
            if not lim then
                return ngx.exit(500)
            end

            local ratelimited, err = lim:is_rate_limited(method,ngx.req.start_time())

            if ratelimited then
                return ngx.exit(503)
            end
        ';

        echo Logged in;
    }

    location /test {
        content_by_lua '
            for i = 0, 3 do
                local res = ngx.location.capture("/login")
                ngx.say("#0", i, ": ", res.status)
                ngx.sleep(0.2)
            end
            ngx.say()
            for i = 0, 3 do
                local res = ngx.location.capture("/filter")
                ngx.say("#1", i, ": ", res.status)
                ngx.sleep(0.2)
            end


        ';
    }
--- request
GET /test
--- timeout: 3000
--- response_body
#00: 200
#01: 200
#02: 503
#03: 503

#10: 200
#11: 503
#12: 503
#13: 503
--- no_error_log
[error]
[warn]

