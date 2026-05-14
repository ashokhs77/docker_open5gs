FROM debian:11

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
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
    libcurl4-openssl-dev \
    msmtp \
    msmtp-mta \
    mailutils \
    python3 \
    python3-pip

RUN pip3 install aiosmtpd

WORKDIR /opt

# Download and build Kannel
RUN wget --no-check-certificate https://www.kannel.org/download/1.5.0/gateway-1.5.0.tar.gz && \
    tar -xzf gateway-1.5.0.tar.gz

WORKDIR /opt/gateway-1.5.0

RUN CFLAGS="-fcommon -fPIC" ./configure --prefix=/usr/local/kannel \
    --with-ssl=/usr && \
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
    CFLAGS="-fcommon" && \
    make && \
    make install

RUN mkdir -p /usr/local/kannel/etc \
    /usr/local/mbuni/etc \
    /tmp/mms-storage

COPY kannel.conf /usr/local/kannel/etc/kannel.conf
COPY mbuni.conf /usr/local/mbuni/etc/mbuni.conf
COPY mmsc_init.sh /mmsc_init.sh
RUN chmod +x /mmsc_init.sh

CMD ["bash","/mmsc_init.sh"]
