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




-- local lim, err = class.new(zone, rate, burst, duration)
function _M.new(zone, rate, circuit_breaker_dict_name, redis_cfg)
    local zone = zone or "ratelimit"
    local rate = rate or "1r/s"
    local circuit_breaker_dict_name = circuit_breaker_dict_name or "ratelimit_circuit_breaker"

    if type(redis_cfg) ~= "table" then
        redis_cfg = {
            host = '127.0.0.1',
            port = 6379,
            timeout = 200,
            dbid = nil
        }
    end

    if redis_cfg['host'] == nil then
        redis_cfg['host'] = '127.0.0.1'
    end

    if redis_cfg['port'] == nil then
        redis_cfg['port'] = 6379
    end

    if redis_cfg['timeout'] == nil then
        redis_cfg['timeout'] = 1000
    end

    if redis_cfg['dbid'] == nil then
        redis_cfg['dbid'] = nil
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


local function redis_create(host, port, timeout_millis, dbid)
    timeout_millis = timeout_millis or 1000
    host = host or "127.0.0.1"
    port = port or 6379

    ngx.log(ngx.CRIT,port)
    ngx.log(ngx.CRIT,timeout_millis)
    ngx.log(ngx.CRIT,dbid)

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

local function expire(premature, key,scale,rd_host,rd_port,timeout,rd_dbid)
    local not_expired = true
    local expire_tries = 0
    local last_err = nil
    while not_expired and expire_tries < 2 do
        expire_tries=expire_tries+1
        local red_exp, last_err = redis_create(rd_host,rd_port,
                                            1000,rd_dbid)
        if red_exp ~= nil then
            local res, last_err = red_exp:expire(key,scale*10)
            if not err then
                not_expired = false
                local ok, err = red_exp:set_keepalive(10000, 1000)
                if not ok then
                    ngx.log(ngx.WARN, "failed to set keepalive: ", err)
                end
            else
                ngx.log(ngx.WARN, "failed to set expire for key: ", last_err)
                red_exp:close()
            end
        end
    end

    if not_expired then
        if is_str(last_err) then
            ngx.log(ngx.ERR,"Unable to set expirey on " .. key .. ":" .. err)
        else
            ngx.log(ngx.ERR,"Unable to set expirey on " .. key)
        end
    end

end

local function increment_limit(premature,rd_host,rd_port,rd_timeout,rd_dbid,dict_name,
                               key,rate,scale,requesttime)

    local red, err = redis_create(rd_host,rd_port,
                                  rd_timeout,rd_dbid)
    if not red then
        ngx.log(ngx.ERR, "failed to talk to redis: ", err)
        return false
    end

    local start_of_period = get_start_of_period(scale,requesttime)
    local curr, old = get_keys(scale,key,start_of_period)

    red:init_pipeline(n)
    red:incr(curr)
    red:get(old)
    local results, err = red:commit_pipeline()

    if results ~= nil then
        local new_count = results[1]
        if new_count == 1 then
            ngx.timer.at(0, expire,curr,scale,rd_host,rd_port,rd_timeout,rd_dbid)
        else
            local res = results[2]

            local old_number_of_requests = 0
            if res ~= null then
                old_number_of_requests = res
            end
            local elapsed = requesttime - start_of_period
            local current_rate = old_number_of_requests * ( (scale - elapsed) / scale) + new_count

            ngx.log(ngx.CRIT,current_rate .. ':' .. rate .. ':' .. old_number_of_requests .. ':' .. new_count)
            if current_rate > rate then
                ngx.log(ngx.CRIT,'open circuit')
                open_circuit(dict_name,key,start_of_period+scale)
            end

            -- put it into the connection pool of size 100,
            -- with 10 seconds max idle time
            local ok, err = red:set_keepalive(10000, 1000)
            if not ok then
                ngx.log(ngx.WARN, "failed to set keepalive: ", err)
            end
        end
    else
        ngx.log(ngx.CRIT,"timeout for incr",err)
        ok, err = red:close()
        if not ok then
            ngx.log(ngx.WARN,"failed to close redis connection")
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
                                     redis_cfg.host, redis_cfg.port,
                                     redis_cfg.timeout, redis_cfg.dbid,
                                     dict_name,formatted_key,
                                     rate,scale,requesttime)
        return false
    end

    return true

end


return _M
