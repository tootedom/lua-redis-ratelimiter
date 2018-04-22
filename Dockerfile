FROM openresty/openresty:centos

RUN yum install -y epel-release \
    && yum install -y redis \
    && /usr/local/openresty/luajit/bin/luarocks install lua-resty-redis \
    && yum clean all

COPY lib/resty/redis/ratelimit.lua /usr/local/openresty/lualib/resty/redis/ratelimit.lua

CMD ["/usr/bin/redis-server", "/etc/redis.conf"]
CMD ["/usr/local/openresty/bin/openresty"]

