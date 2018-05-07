FROM openresty/openresty:centos

COPY OpenResty.repo /etc/yum.repos.d/OpenResty.repo

RUN yum install -y epel-release \
    && yum install -y redis \
    && yum groupinstall -y "Development Tools" \
    && yum install git \
    && yum install -y openssl-devel \
    && yum install -y which \
    && yum install -y jq \
    && export PERL_MM_USE_DEFAULT=1 \
    && PERL_MM_USE_DEFAULT=1 yum install perl-CPAN perl-Test-Base -y \
    && PERL_MM_USE_DEFAULT=1 yum install perl-List-MoreUtils -y \
    && yum install perl-Test-LongString -y \
    && yum install -y perl-Test-Nginx \
    && /usr/local/openresty/luajit/bin/luarocks install lua-resty-redis \
    && yum clean all \
    && git clone https://github.com/giltene/wrk2.git \
    && cd wrk2 \
    && make \
    && cp wrk /usr/local/bin \
    && cd .. && rm -rf wrk2


