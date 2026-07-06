FROM debian:11 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    autoconf \
    automake \
    libtool \
    pkg-config \
    wget \
    ca-certificates \
    gettext \
    git \
    libxml2-dev \
    libssl-dev \
    libmariadb-dev \
    libpcre3-dev \
    libcurl4-openssl-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt

# Download and build Kannel
RUN wget --no-check-certificate https://www.kannel.org/download/1.5.0/gateway-1.5.0.tar.gz && \
    tar -xzf gateway-1.5.0.tar.gz

WORKDIR /opt/gateway-1.5.0

RUN CFLAGS="-fcommon -fPIC -I/usr/include/openssl" \
    LDFLAGS="-L/usr/lib/x86_64-linux-gnu -lssl -lcrypto" \
    ./configure --prefix=/usr/local/kannel \
    --with-ssl=/usr \
    --enable-ssl && \
    make && \
    make install

# Download Mbuni
WORKDIR /opt

RUN wget --no-check-certificate http://mbuni.org/downloads/1.6.0/mbuni-1.6.0.tar.gz && \
    tar -xzf mbuni-1.6.0.tar.gz

WORKDIR /opt/mbuni-1.6.0

RUN ln -s /usr/bin/automake /usr/bin/automake-1.9 && \
    ln -s /usr/bin/aclocal /usr/bin/aclocal-1.9 && \
    ./bootstrap && \
    ./configure --prefix=/usr/local/mbuni \
    --with-kannel-dir=/usr/local/kannel \
    CFLAGS="-fcommon" 

# Increase MAX_MESSAGE_SIZE from 100KB to 10MB for high quality photos/videos
RUN sed -i 's/#define MAX_MESSAGE_SIZE 100\*1024/#define MAX_MESSAGE_SIZE 10*1024*1024/' \
    /opt/mbuni-1.6.0/mmsc/mmsproxy.c && \
    grep "MAX_MESSAGE_SIZE" /opt/mbuni-1.6.0/mmsc/mmsproxy.c | head -3

# Always use MAX_MESSAGE_SIZE, ignore UAProf size limit
RUN sed -i 's/prof ? mms_ua_maxmsgsize(prof) : MAX_MESSAGE_SIZE/MAX_MESSAGE_SIZE/g' \
    /opt/mbuni-1.6.0/mmsc/mmsproxy.c && \
    grep -n "MAX_MESSAGE_SIZE\|mms_ua_maxmsgsize" \
    /opt/mbuni-1.6.0/mmsc/mmsproxy.c | head -5

RUN make && make install && \
    (find /usr/local/kannel /usr/local/mbuni -type f \( -path '*/bin/*' -o -path '*/sbin/*' -o -name '*.so*' \) -exec strip --strip-unneeded {} + 2>/dev/null || true)

FROM debian:11

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4 \
    libmariadb3 \
    libpcre3 \
    libssl1.1 \
    libxml2 \
    msmtp \
    msmtp-mta \
    python3 \
    python3-pip && \
    pip3 install --no-cache-dir aiosmtpd && \
    apt-get purge -y --auto-remove python3-pip && \
    rm -rf /var/lib/apt/lists/* /root/.cache /tmp/*

COPY --from=builder /usr/local/kannel /usr/local/kannel
COPY --from=builder /usr/local/mbuni /usr/local/mbuni

RUN mkdir -p /usr/local/kannel/etc \
    /usr/local/mbuni/etc \
    /tmp/mms-storage

COPY kannel.conf /usr/local/kannel/etc/kannel.conf
COPY mbuni.conf /usr/local/mbuni/etc/mbuni.conf
COPY mmsc_init.sh /mmsc_init.sh
RUN chmod +x /mmsc_init.sh

CMD ["bash","/mmsc_init.sh"]

