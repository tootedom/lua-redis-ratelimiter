FROM openresty/openresty:centos

RUN yum install -y epel-release \
    && yum install -y redis \
    && yum groupinstall -y "Development Tools" \
    && yum install git \
    && yum install -y openssl-devel \
    && /usr/local/openresty/luajit/bin/luarocks install lua-resty-redis \
    && yum clean all \
    && git clone https://github.com/giltene/wrk2.git \
    && cd wrk2 \
    && make \
    && cp wrk /usr/local/bin \
    && cd .. && rm -rf wrk2

COPY lib/resty/redis/ratelimit.lua /usr/local/openresty/lualib/resty/redis/ratelimit.lua

CMD ["/usr/bin/redis-server", "/etc/redis.conf"]
CMD ["/usr/local/openresty/bin/openresty"]

