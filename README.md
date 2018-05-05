# Name



# Table of Contents

* [Status](#status)
* [Description](#description)
* [Synopsis](#synopsis)
* [Methods](#methods)
    * [new](#new)

# Status

In Development

----

# Synopsis

Implementation of global rate limiting for nginx using Redis as a back end.

----

# Description

There are a couple of variations of the rate limiting within the library, depending upon your needs for
accuracy and/or performance.  The recommended ratelimiter is the *background* ratelimiter that is based
the cloudflare ratelimiter as described on this blog (I have no knowledge of the actual implementation details of the cloudflare rate limiter.  The implementation in here is soley based on the details described on the following blog):

- https://blog.cloudflare.com/counting-things-a-lot-of-different-things/

All of the rate limiting implementations share the same fundamental algorithm of the leaky bucket algorithm, and use the same approximation calculation as specified on the above blog:

```
rate = number_of_requests_in_previous_window * ((window_period - elasped_time_in_current_period) / window_period) + number_of_requests_in_current_window
```

# Leaky Bucket and Sliding Window

All the implementations provided use the same concept of:

- leaky bucket
- sliding window

This is implemented by storing in REDIS two counters per key (the key being the item you chose to rate limit on: ip address, client token).

When you check if a request is rate limited you pass in the [ngx.req.start_time()](https://github.com/openresty/lua-nginx-module#ngxreqstart_time).  If you are rate limiting using requests per second (r/s), the time is rounded down to the start of the second.  If you are rate limiting using requests per minute (r/m), the time is rounded down to the start of that second's minute.  

The counter that is incremented for each request is recorded against that rounded down time.

As a result we store 2 keys in Redis per rate limit counter.  The currently incrementing counter, and the previous period's counter.

For example for the following:
```
local key = ngx.var.remote_addr
local is_rate_limited = lim:is_rate_limited(key, ngx.req.start_time())
```

The keys in REDIS will look something like the following, for rate limit by seconds:

- PREVIOUS: <zone>:127.0.0.1_1525032761 == 2
- CURRENT:  <zone>:127.0.0.1_1525032762 == 2

The keys in REDIS will look something like the following, for rate limit by minute:

- PREVIOUS: <zone>:127.0.0.1_1525514700 == 0
- CURRENT:  <zone>:127.0.0.1_1525514760 == 2


When the rate limit is exceeded, a key entry for the current period is placed in within an [nginx shared dict](https://github.com/openresty/lua-nginx-module#ngxshareddict).  We can then check the shared dict to see if the rate has been exceeded for the current key without having to talk to REDIS.  The entry in the shared dict lasts for (expires after) the remaining time left in the current time window (i.e. if we are 15 seconds into the current minute, the entry will expire after 45 seconds).  The entry in the dict is based on the `<zone>:<key>`

The shared dict by default is named `ratelimit_circuit_breaker`, but can be changed per rate limiting object

```
lua_shared_dict authorisationapi_ratelimit_circuit_breaker 1m;
lua_shared_dict logic_ratelimit_circuit_breaker 1m;
```

```
location /login {
    access_by_lua_block {
        local config = { circuit_breaker_dict_name = "filter_ratelimit_circuit_breaker" }
        local zone = "filter"
        local lim, _ = ratelimit.new(zone, "2r/s", config)
    }
    ...
}
```

If you are using multiple shared dicts, you still need to made sure the "zone" is set differently, as the key will be stored in the same redis (unless you are configuring multiple redis endpoint, for rate limiting)

----




----

# Background Ratelimiter

The background ratelimiter relies on the use of [nginx shared dicts](https://github.com/openresty/lua-nginx-module#ngxshareddict)





```
    location /t {
        access_by_lua_block {

            local ratelimit = require "resty.redis.ratelimiter.background"
            local red = { host = "127.0.0.1", port = 6379, timeout = 100 , expire_after_seconds = 5}
            local lim, err = ratelimit.new("one", "2r/s", "ratelimit_circuit_breaker", red)
            if not lim then
                ngx.log(ngx.ERR,
                        "failed to instantiate a resty.redis.ratelimiter.background object: ", err)
                return ngx.exit(500)
            end

            local key = ngx.var.binary_remote_addr
            local is_rate_limited = lim:is_rate_limited(key, ngx.req.start_time())

            if is_rate_limited then
                return ngx.exit(429)
            end

        }

        content_by_lua_block {
             ngx.say('Hello,world!')
        }
    }
```

----

# See Also

* Rate Limiting with NGINX: https://www.nginx.com/blog/rate-limiting-nginx/
* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: https://openresty.org/

[Back to TOC](#table-of-contents)
