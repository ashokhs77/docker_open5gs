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

FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive
ENV DEB_BUILD_PROFILES="pkg.ngcp-rtpengine.nobcg729"

# 1. Add contrib and non-free to get all media libraries
RUN sed -i 's/Components: main/Components: main contrib non-free/g' /etc/apt/sources.list.d/debian.sources

# 2. Install all build dependencies
RUN apt-get update && \
	apt-get -y install \
		git \
		dpkg-dev \
		debhelper \
		gperf \
		default-libmysqlclient-dev \
		libevent-dev \
		libhiredis-dev \
		libiptc-dev \
		libjson-glib-dev \
		libpcap0.8-dev \
		libpcre3-dev \
		libssl-dev \
		libsystemd-dev \
		libxmlrpc-core-c3-dev \
		libglib2.0-dev \
		zlib1g-dev \
		libcurl4-openssl-dev \
		libwebsockets-dev \
		libxtables-dev \
		libavcodec-dev \
		libavfilter-dev \
		libavformat-dev \
		libavutil-dev \
		libswresample-dev \
		libspandsp-dev \
		libavcodec-extra \
		libopencore-amrnb-dev \
		libopencore-amrwb-dev \
		vim \
		tmux \
		netcat-openbsd \
		iptables \
		iproute2 \
		net-tools \
		iputils-ping \
		nftables \
		dh-sequence-dkms \
		discount \
		libbencode-perl \
		libcrypt-openssl-rsa-perl \
		libcrypt-rijndael-perl \
		libdigest-crc-perl \
		libdigest-hmac-perl \
		libio-multiplex-perl \
		libio-socket-inet6-perl \
		libjson-perl \
		libjwt-dev \
		libmnl-dev \
		libmosquitto-dev \
		libncurses-dev \
		libnet-interface-perl \
		libnftnl-dev \
		libopus-dev \
		libsocket6-perl \
		libtest2-suite-perl \
		liburing-dev \
		libwww-perl \
		pandoc \
		python3-websockets \
		systemd

# 3. Fetch RTPEngine code, checkout the version you want, build and install
RUN git clone https://github.com/sipwise/rtpengine && \
	cd rtpengine && \
	git checkout mr13.5.1.1 && \
	dpkg-checkbuilddeps && \
	export DEB_BUILD_OPTIONS=nocheck && dpkg-buildpackage -b -uc -us && \
	cd .. && \
	# Use apt-get install, which can resolve dependencies between local .deb files
	apt-get install -y ./*.deb && \
	ldconfig && \
	# And use the same wildcard to clean them up
	rm -rf rtpengine *.buildinfo *.changes *.deb *.tar.xz

# 4. Install any remaining runtime dependencies (good safety net)
RUN apt-get -f install -y


CMD ["/mnt/rtpengine/rtpengine_init.sh"]





