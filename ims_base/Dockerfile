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

FROM ubuntu:jammy AS builder

ARG LICENSE=OFF
ENV LICENSE=${LICENSE}

ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies only in the builder stage.
RUN apt-get update && \
	apt-get -y install --no-install-recommends git-core \
					gcc flex bison libmysqlclient-dev make libssl-dev libcurl4-openssl-dev \
					libxml2-dev libpcre2-dev bash-completion g++ autoconf libmnl-dev \
					libsctp-dev libradcli-dev libradcli4 libjson-c-dev pkg-config iproute2 net-tools \
					iputils-ping libgcrypt20-dev libjansson-dev libevent-dev libnghttp2-dev uuid-dev \
					ca-certificates && \
	rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/log/kamailio/

# Copy license library into system lib path
COPY license/libLwsLicenseCheck.so /usr/lib64/
RUN chmod 777 /usr/lib64/libLwsLicenseCheck.so

# Fetch Kamailio code
RUN mkdir -p /usr/local/src/ && cd /usr/local/src/ && \
	git init kamailio && \
	cd kamailio && \
	git remote add origin https://github.com/ganeshsskumar/kamailio && \
	git fetch --depth 1 origin 02b50932040e922839053300748739da9ea29dd6 && \
	git checkout FETCH_HEAD

# Build and Install Kamailio
RUN cd /usr/local/src/kamailio && make cfg
RUN if [ "$LICENSE" = "ON" ]; then \
        echo "Injecting LICENSE macro into Kamailio build"; \
        echo 'DEFS+=-DENABLE_LICENSE_CHECK' >> /usr/local/src/kamailio/src/Makefile.defs; \
    fi
COPY modules.lst /usr/local/src/kamailio/src

RUN cd /usr/local/src/kamailio && \
	make -j`nproc` Q=0 all && \
	make install && \
	(find /usr/local -type f \( -path '*/sbin/*' -o -path '*/lib/*' \) -exec strip --strip-unneeded {} + 2>/dev/null || true)

FROM ubuntu:jammy

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
	apt-get -y install --no-install-recommends \
		ca-certificates \
		default-mysql-client \
		iproute2 \
		iputils-ping \
		net-tools \
		libcurl4 \
		libevent-2.1-7 \
		libevent-openssl-2.1-7 \
		libgcrypt20 \
		libjansson4 \
		libjson-c5 \
		libmnl0 \
		libmysqlclient21 \
		libnghttp2-14 \
		libpcre2-8-0 \
		libpcre3 \
		netbase \
		libradcli4 \
		libsctp1 \
		libssl3 \
		libuuid1 \
		libxml2 && \
	rm -rf /var/lib/apt/lists/*

# Copy Kamailio runtime files only — omit 312MB build source tree not needed at runtime.
# The full COPY --from=builder /usr/local /usr/local was replaced with targeted copies
# to exclude /usr/local/src (312MB), /usr/local/include (headers), and /usr/local/share/doc.
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /usr/local/etc /usr/local/etc
COPY --from=builder /usr/local/lib /usr/local/lib
COPY --from=builder /usr/local/lib64 /usr/local/lib64
COPY --from=builder /usr/local/sbin /usr/local/sbin
COPY --from=builder /usr/local/share/kamailio /usr/local/share/kamailio
# SQL schema files needed by init scripts for MySQL database setup at container startup
COPY --from=builder /usr/local/src/kamailio/utils/kamctl/mysql /usr/local/src/kamailio/utils/kamctl/mysql
COPY --from=builder /usr/local/src/kamailio/misc/examples/ims/icscf /usr/local/src/kamailio/misc/examples/ims/icscf

RUN mkdir -p /var/log/kamailio/ && ldconfig

COPY kamailio-cdr /etc/logrotate.d/kamailio-cdr

COPY cdr_logger.sh /usr/local/bin/cdr-logger.sh

RUN chmod +x /usr/local/bin/cdr-logger.sh

COPY license/libLwsLicenseCheck.so /usr/lib64/
RUN chmod 755 /usr/lib64/libLwsLicenseCheck.so

COPY kamailio_init.sh /
CMD ["/kamailio_init.sh"]

