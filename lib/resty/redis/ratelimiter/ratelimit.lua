-- Copyright (C) Dominic Tootell, Greencheek.org

local redis = require "resty.redis"
local ngx = require "ngx"

local type = type
local assert = assert
local floor = math.floor
local tonumber = tonumber
local null = ngx.null


local _M = {
    _VERSION = "0.03",
}

local mt = {
    __index = _M
}

local function is_str(s)
    return type(s) == "string"
end


local function redis_create(host, port, timeout_millis, dbid)
    timeout_millis = timeout_millis or 100
    host = host or "127.0.0.1"
    port = port or 6379

    local red = redis:new()

    red:set_timeout(timeout_millis)

    local redis_err = function(err)
        local msg = "failed to create redis"
        if is_str(err) then
            msg = msg .. " - " .. err
        end

        return msg
    end

    local ok, err = red:connect(host, port)
    if not ok then
        return nil, redis_err(err)
    end

    if dbid then
        local ok, err = red:select(dbid)
        if not ok then
            return nil, redis_err(err)
        end
    end

    return red
end


-- local lim, err = class.new(zone, rate, burst, duration)
function _M.new(zone, rate, circuit_breaker_dict_name, redis_cfg)
    local zone = zone or "ratelimit"
    local rate = rate or "1r/s"
    local circuit_breaker_dict_name = circuit_breaker_dict_name or "ratelimit_circuit_breaker"

    if type(redis_cfg) ~= "table" then
        redis_cfg = {}
    end

    local scale = 1
    local len = #rate

    if len > 3 and rate:sub(len - 2) == "r/s" then
        rate = rate:sub(1, len - 3)
    elseif len > 3 and rate:sub(len - 2) == "r/m" then
        scale = 60
        rate = rate:sub(1, len - 3)
    end

    rate = tonumber(rate)

    assert(rate > 0 and scale >= 0)

    return setmetatable({
            zone = zone,
            rate = rate,
            scale = scale,
            circuit_breaker_dict_name = circuit_breaker_dict_name,
            redis_cfg = redis_cfg,
    }, mt)
end



-- Returns the current key
-- and the previous key based on the current nginx request time.
function get_keys(scale, key, start_of_period)
    return string.format("%s_%d",key,start_of_period),string.format("%s_%d",key,start_of_period-scale)
end


local function is_circuit_open(dict_name,key,requesttime)
    local dict = ngx.shared[dict_name]
    if dict ~= nil then
        local limited = dict:get(key)
        if limited ~= nil then
            if requesttime < limited then
                return true
            end
            dict:delete(key)
            return false
        end
        return false
    end
    return false
end

local function open_circuit(dict_name,key,time)
    local dict = ngx.shared[dict_name]
    if dict ~= nil then
        dict:set(key,time)
    end
end

local function get_start_of_period(scale,requesttime)
    local seconds = math.floor(requesttime)
    if scale == 60 then
        -- It is requests per min
        local minute = seconds - seconds%60
        return minute
    end
    return seconds
end

--
local function rate_limit(redis, dict_name, zone, key, rate, scale, requesttime)
    local key = zone .. ":" .. key
    if is_circuit_open(dict_name,key,requesttime) then
        return true
    end

    local start_of_period = get_start_of_period(scale,requesttime)
    local curr, old = get_keys(scale,key,start_of_period)

    res, err = redis:mget(curr, old)
    if err == nil then

        local old_number_of_requests = 0
        local current_number_of_requests = 1
        if res[1] ~= null then
            current_number_of_requests = res[1]+1
        end

        if res[2] ~= null then
            old_number_of_requests = res[2]
        end

        local elapsed = requesttime - start_of_period
        current_rate = old_number_of_requests * ( (scale - elapsed) / scale) + current_number_of_requests

        ngx.log(ngx.CRIT,current_rate)
        if current_rate > rate then
            open_circuit(dict_name,key,start_of_period+scale)
            return true
        end

        redis:incr(curr)
        redis:expire(curr,scale)
        return false
    end
    return false
end


-- local delay, err = lim:incoming(key, redis)
function _M.is_rate_limited(self, key, requesttime)

    local red, err = redis_create(self.redis_cfg.host, self.redis_cfg.port,
                                  self.redis_cfg.timeout,self.redis_cfg.dbid)
    if not red then
        ngx.log(ngx.ERR, "failed to talk to redis: ", err)
        return false
    end

    local res = rate_limit(
        red, self.circuit_breaker_dict_name, self.zone, key, self.rate,
        self.scale, requesttime)

    -- put it into the connection pool of size 100,
    -- with 10 seconds max idle time
    local ok, err = red:set_keepalive(10000, 100)
    if not ok then
        ngx.log(ngx.WARN, "failed to set keepalive: ", err)
    end

    return res

end


return _M
