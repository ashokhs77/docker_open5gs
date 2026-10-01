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
        libbcg729-dev \
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
        wget \
        unzip \
        patch \
        ca-certificates \
        zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch mr26.0 https://github.com/sipwise/rtpengine /src/rtpengine

# --- EVS: fetch 3GPP/ETSI reference source, apply rtpengine's patch, build lib3gpp-evs.so
RUN mkdir -p /tmp/evs && cd /tmp/evs && \
    wget -q -U "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36" \
        https://www.etsi.org/deliver/etsi_ts/126400_126499/126443/17.00.00_60/ts_126443v170000p0.zip && \
    unzip -qq ts_126443v170000p0.zip && \
    cd ./c-code && \
    patch -p1 < /src/rtpengine/evs/etsi-ts-126.443-3gpp-ts-26.443-v17.0.0/patch && \
    chmod +r ./lib_*/*.h && \
    mkdir -p /usr/include/3gpp-evs && \
    cp --target-directory=/usr/include/3gpp-evs ./lib_*/*.h && \
    DEBUG=0 RELEASE=1 make && \
    mkdir -p /evs-lib && \
    cp ./lib3gpp-evs.so /evs-lib/lib3gpp-evs.so

RUN cd /src/rtpengine && \
    dpkg-checkbuilddeps && \
    export DEB_BUILD_OPTIONS=nocheck && \
    dpkg-buildpackage -b -uc -us && \
    mkdir -p /rtpengine-debs && \
    cp /src/*.deb /rtpengine-debs/

FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN sed -i 's/Components: main/Components: main contrib non-free/g' /etc/apt/sources.list.d/debian.sources

COPY --from=builder /rtpengine-debs /tmp/rtpengine-debs
# --- EVS: pull the built lib in from the builder stage
COPY --from=builder /evs-lib/lib3gpp-evs.so /usr/local/lib/rtpengine/lib3gpp-evs.so

RUN apt-get update && \
    debs="$(find /tmp/rtpengine-debs -maxdepth 1 -type f \( -name 'ngcp-rtpengine-daemon_*.deb' -o -name 'ngcp-rtpengine-iptables_*.deb' -o -name 'ngcp-rtpengine-utils_*.deb' \) -print)" && \
    test -n "$debs" && \
    apt-get -y install --no-install-recommends \
        libavcodec-extra \
        libbcg729-0 \
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

# --- EVS: point rtpengine at the built lib

RUN mkdir -p /etc/rtpengine && \
    sed -i '/^\[rtpengine\]/a evs-lib-path = /usr/local/lib/rtpengine/lib3gpp-evs.so' \
        /etc/rtpengine/rtpengine.conf

CMD ["/mnt/rtpengine/rtpengine_init.sh"]

