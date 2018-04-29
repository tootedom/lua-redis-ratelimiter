-- Copyright (C) Dominic Tootell, Greencheek.org

local redis = require "resty.redis"
local ngx = require "ngx"

local type = type
local assert = assert
local floor = math.floor
local tonumber = tonumber
local null = ngx.null

local redis_host_default = '127.0.0.1'
local redis_port_default = 6379
local redis_timeout_default = 300
local redis_dbid_default = nil

local FAILED_TO_RETURN_CONNECTION = "failed_returning_connection_to_pool"
local FAILED_TO_SET_KEY_EXPIRY = "failed_set_key_expiry"

local _M = {
    _VERSION = "0.03",
}

local mt = {
    __index = _M
}

local function is_str(s)
    return type(s) == "string"
end


local function _redis_defaults(redis_cfg,window_size_in_seconds)
    if redis_cfg['host'] == nil then
        redis_cfg['host'] = redis_host_default
    end

    if redis_cfg['port'] == nil then
        redis_cfg['port'] = redis_port_default
    end

    if redis_cfg['timeout'] == nil then
        redis_cfg['timeout'] = redis_timeout_default
    end

    if redis_cfg['dbid'] == nil then
        redis_cfg['dbid'] = redis_dbid_default
    end

    if redis_cfg['idle_keepalive_ms'] == nil then
        redis_cfg['idle_keepalive_ms'] = 10000
    end

    if redis_cfg['connection_pool_size'] == nil then
        redis_cfg['connection_pool_size'] = 100
    end

    if redis_cfg['expire_after_seconds'] == nil then
        redis_cfg['expire_after_seconds'] = window_size_in_seconds * 5
    end
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

    if len>3 then
        -- check for requests per minute.
        -- default is requests per second
        local rate_type = rate:sub(len - 2)
        rate = rate:sub(1, len - 3)
        if rate_type == "r/m" then
            scale = 60
        end
    else
        rate = 1
    end

    rate = tonumber(rate)

    _redis_defaults(redis_cfg,scale)

    assert(rate > 0 and scale >= 0)
    assert(redis_cfg['expire_after_seconds'] >= (scale * 3))

    return setmetatable({
            zone = zone,
            rate = rate,
            scale = scale,
            circuit_breaker_dict_name = circuit_breaker_dict_name,
            redis_cfg = redis_cfg,
    }, mt)
end


local function _redis_create(host, port, timeout_millis, dbid)

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

-- Returns the current key
-- and the previous key based on the current nginx request time.
local function get_keys(scale, key, start_of_period)
    return string.format("%s_%d",key,start_of_period),string.format("%s_%d",key,start_of_period-scale)
end


local function is_circuit_open(dict_name,key,requesttime)
    local dict = ngx.shared[dict_name]
    if dict ~= nil then
        local limited = dict:get(key)
        if limited ~= nil then
            if requesttime <= limited then
                return true
            end
            dict:delete(key)
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

local function expire(premature, key,scale,rd_cfg)
    local not_expired = true
    local expire_tries = 0
    local last_err = nil
    local retry = true

    while retry do
        expire_tries=expire_tries+1
        local red_exp, last_err = _redis_create(rd_cfg.host,rd_cfg.port,
                                                rd_cfg.timeout,rd_cfg.dbid)
        if red_exp ~= nil then
            local res, last_err = red_exp:expire(key,rd_cfg.expire_after_seconds)
            if last_err == nil then
                not_expired = false
                retry = false
                local ok, err = red_exp:set_keepalive(rd_cfg.idle_keepalive_ms, rd_cfg.connection_pool_size)
                if not ok then
                    ngx.log(ngx.WARN,'|{"level" : "WARN", "msg" : "' .. FAILED_TO_RETURN_CONNECTION .. '"}|', err)
                end
            else
                retry = expire_tries <= 2
                if retry then
                    ngx.log(ngx.WARN, '|{"level" : "WARN", "msg" : "' .. FAILED_TO_SET_KEY_EXPIRY .. '", "key": "' .. key .. '", "retry" : "true" }|', last_err)
                else
                    ngx.log(ngx.ERR, '|{"level" : "ERROR", "msg" : "' .. FAILED_TO_SET_KEY_EXPIRY .. '", "key": "' .. key .. '", "retry" : "false" }|', last_err)
                end
                red_exp:close()
            end
        end
    end

    if not_expired then
        if is_str(last_err) then
            ngx.log(ngx.ERR,'|{"level" : "ERROR", "msg" : "' .. FAILED_TO_SET_KEY_EXPIRY .. '", "key": "' .. key .. '" }|', last_err)
        else
            ngx.log(ngx.ERR,'|{"level" : "ERROR", "msg" : "' .. FAILED_TO_SET_KEY_EXPIRY .. '", "key": "' .. key .. '" }|')
        end
    end

end

local function increment_limit(premature,rd_cfg,dict_name,
                               key,rate,scale,requesttime)

    local red, err = _redis_create(rd_cfg.host,rd_cfg.port,
                                   rd_cfg.timeout,rd_cfg.dbid)
    if not red then
        ngx.log(ngx.ERR, '|{"level" : "ERROR", "msg" : "failed_connecting_to_redis", "incremented_counter":"false", "key" : "' .. key .. '" }|', err)
        return false
    end

    local start_of_period = get_start_of_period(scale,requesttime)
    local currrent_period_key, previous_period_key = get_keys(scale,key,start_of_period)

    red:init_pipeline(n)
    red:incr(currrent_period_key)
    red:get(previous_period_key)
    local results, err = red:commit_pipeline()

    if results ~= nil then
        ngx.log(ngx.INFO,'|{"level" : "INFO", "incremented_counter" : "true", "key" : "' .. key .. '"}|')
        local new_count = results[1]
        if new_count == 1 then
            ngx.timer.at(0, expire,currrent_period_key,scale,rd_cfg)
        else
            local res = results[2]

            local old_number_of_requests = 0
            if res ~= null then
                old_number_of_requests = res
            end
            local elapsed = requesttime - start_of_period
            local current_rate = old_number_of_requests * ( (scale - elapsed) / scale) + new_count

            ngx.log(ngx.INFO,'|{"level" : "INFO",  "key" : "' .. key .. '", "msg" : "current_rate_report", "previous_period_key" : "' .. previous_period_key  .. '", "current_period_key" : "' .. currrent_period_key .. '", "number_of_old_requests" : ' .. old_number_of_requests .. ', "number_of_new_requests" : ' .. new_count .. ', "elasped_time_in_current_period" : ' .. elapsed .. ' , "current_rate" : ' .. current_rate .. ', "rate_limit" : ' .. rate .. ' }|')

            if current_rate >= rate then
                ngx.log(ngx.INFO,'|{"level" : "INFO",  "key" : "' .. key .. '" , "msg" : "opening_rate_limit_circuit", "number_of_old_requests" : ' .. old_number_of_requests .. ', "number_of_new_requests" : ' .. new_count .. ', "current_rate" : ' .. current_rate .. ', "rate_limit" : ' .. rate .. ' }|')
                open_circuit(dict_name,key,start_of_period+scale)
            end

            -- put it into the connection pool
            local ok, err = red:set_keepalive(rd_cfg.idle_keepalive_ms, rd_cfg.connection_pool_size)
            if not ok then
                ngx.log(ngx.INFO,'|{"level" : "INFO", "msg" : "failed_returning_connection_to_pool"}|', err)
            end
        end
    else
        ngx.log(ngx.ERR,'|{"level" : "ERROR", "msg" : "increment_rate_limit_timeout",  "incremented_counter" : "false", "key" : "' .. key .. '" }|',err)
        ok, err = red:close()
        if not ok then
            ngx.log(ngx.INFO,'|{"level" : "INFO", "msg" : "failed_closing_connection"}|',err)
        end
    end

end

--
local function is_request_allowed(dict_name, key, requesttime)
    if is_circuit_open(dict_name,key,requesttime) then
        return false
    end

    return true
end


-- local delay, err = lim:incoming(key, redis)
function _M.is_rate_limited(self, key, requesttime)
    local formatted_key =  self.zone .. ":" .. key
    local dict_name = self.circuit_breaker_dict_name
    local redis_cfg = self.redis_cfg
    local rate = self.rate
    local scale = self.scale

    if is_request_allowed(dict_name,formatted_key,requesttime) then
        local ok, err = ngx.timer.at(0, increment_limit,
                                     redis_cfg,
                                     dict_name,formatted_key,
                                     rate,scale,requesttime)
        return false
    end

    return true

end


return _M
