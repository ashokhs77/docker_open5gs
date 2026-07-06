# BSD 2-Clause License

# Copyright (c) 2020-2025, Supreeth Herle
# All rights reserved.

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:

# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.

# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.

# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

FROM debian:bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV DEB_BUILD_PROFILES="pkg.ngcp-rtpengine.nobcg729"

RUN sed -i 's/Components: main/Components: main contrib non-free/g' /etc/apt/sources.list.d/debian.sources

RUN apt-get update && \
    apt-get -y install --no-install-recommends \
        debhelper \
        build-essential \
        default-libmysqlclient-dev \
        dh-sequence-dkms \
        discount \
        dpkg-dev \
        git \
        gperf \
        iproute2 \
        iptables \
        iputils-ping \
        libavcodec-dev \
        libavcodec-extra \
        libavfilter-dev \
        libavformat-dev \
        libavutil-dev \
        libbencode-perl \
        libcjson-dev \
        libcrypt-openssl-rsa-perl \
        libcrypt-rijndael-perl \
        libcurl4-openssl-dev \
        libdigest-crc-perl \
        libdigest-hmac-perl \
        libevent-dev \
        libglib2.0-dev \
        libhiredis-dev \
        libio-multiplex-perl \
        libio-socket-inet6-perl \
        libiptc-dev \
        libjson-glib-dev \
        libjson-perl \
        libjwt-dev \
        libmnl-dev \
        libmosquitto-dev \
        libncurses-dev \
        libnet-interface-perl \
        libnftnl-dev \
        libopencore-amrnb-dev \
        libopencore-amrwb-dev \
        libopus-dev \
        libpcap0.8-dev \
        libpcre3-dev \
        libsocket6-perl \
        libspandsp-dev \
        libssl-dev \
        libswresample-dev \
        libsystemd-dev \
        libtest2-suite-perl \
        liburing-dev \
        libvo-amrwbenc-dev \
        libwebsockets-dev \
        libwww-perl \
        libxmlrpc-core-c3-dev \
        libxtables-dev \
        net-tools \
        netcat-openbsd \
        nftables \
        pandoc \
        python3-websockets \
        systemd \
        zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch mr26.0 https://github.com/sipwise/rtpengine /src/rtpengine && \
    cd /src/rtpengine && \
    dpkg-checkbuilddeps && \
    export DEB_BUILD_OPTIONS=nocheck && \
    dpkg-buildpackage -b -uc -us && \
    mkdir -p /rtpengine-debs && \
    cp /src/*.deb /rtpengine-debs/

FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN sed -i 's/Components: main/Components: main contrib non-free/g' /etc/apt/sources.list.d/debian.sources

COPY --from=builder /rtpengine-debs /tmp/rtpengine-debs

RUN apt-get update && \
    debs="$(find /tmp/rtpengine-debs -maxdepth 1 -type f \( -name 'ngcp-rtpengine-daemon_*.deb' -o -name 'ngcp-rtpengine-iptables_*.deb' -o -name 'ngcp-rtpengine-utils_*.deb' \) -print)" && \
    test -n "$debs" && \
    apt-get -y install --no-install-recommends \
        iproute2 \
        iptables \
        iputils-ping \
        kmod \
        net-tools \
        netcat-openbsd \
        nftables \
        procps \
        $debs && \
    ldconfig && \
    rm -rf /tmp/rtpengine-debs /var/lib/apt/lists/* /root/.cache /tmp/*

CMD ["/mnt/rtpengine/rtpengine_init.sh"]

