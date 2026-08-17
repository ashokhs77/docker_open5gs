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
ARG EPC_VERSION=unknown
ENV LICENSE=${LICENSE}

ENV DEBIAN_FRONTEND=noninteractive

# Install updates and dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3-pip \
        python3-setuptools \
        python3-wheel \
        ninja-build \
        build-essential \
        flex \
        bison \
        git \
        cmake \
        libsctp-dev \
        libgnutls28-dev \
        libgcrypt-dev \
        libssl-dev \
        libidn11-dev \
        libmongoc-dev \
        libbson-dev \
        libyaml-dev \
        meson \
     #   mongodb \
      #  curl \
        gnupg \
        ca-certificates \
        libmicrohttpd-dev \
        libcurl4-gnutls-dev \
        libnghttp2-dev \
        libtins-dev \
        libidn11-dev \
        libtalloc-dev && \
    rm -rf /var/lib/apt/lists/*

#RUN mkdir -p /etc/apt/keyrings
#RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
#    NODE_MAJOR=20 && \
#    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list && \
#    apt-get update && apt install nodejs -y

# Copy license library into system lib path
COPY license/libLwsLicenseCheck.so /usr/lib64/
RUN chmod 777 /usr/lib64/libLwsLicenseCheck.so 

# Refresh library linker cache
RUN ldconfig

# Get open5gs code and install. Fetch only the pinned commit to keep build
# cache and builder layers small.
RUN git init open5gs && cd open5gs && \
    git remote add origin https://github.com/ashokhs77/open5gs && \
    git fetch --depth 1 origin d6cce54d43c672d6b54e281f90293ede4c3b1fcc && \
    git checkout FETCH_HEAD && \
    git submodule update --init --recursive --depth 1 && \
    if [ "$LICENSE" = "OFF" ]; then \
        echo "Disabling MME License"; \
        sed -i "s/, *'-DENABLE_LICENSE_CHECK'//g" src/mme/meson.build; \
    else \
        echo "MME License Enabled"; \
    fi && \
    meson build --prefix=`pwd`/install && \
    ninja -C build && cd build && ninja install && \
    (find ../install/bin ../install/lib -type f -exec strip --strip-unneeded {} + 2>/dev/null || true)

# NOTE: The MME/AMF unauthorized-attach / mobility-reject audit feature is now
# part of the pinned open5gs source (github.com/ashokhs77/open5gs), so it is
# compiled by the meson/ninja build above. No patch is applied here anymore.

# Building WebUI of open5gs
#RUN cd open5gs/webui && npm ci

# Build final image
FROM ubuntu:jammy

ARG EPC_VERSION=unknown
LABEL org.opencontainers.image.version="${EPC_VERSION}" \
      com.lekhawireless.epc.revision="${EPC_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        libssl3 \
        libyaml-0-2 \
        libmicrohttpd12 \
        libmongoc-1.0-0 \
        libbson-1.0-0 \
        libsctp1 \
        libcurl3-gnutls \
        libtins4.0 \
        libidn12 \
        libtalloc2 \
        netbase \
        ifupdown \
        iproute2 \
        iputils-ping \
        python3 \
        python3-click \
        iptables \
	iperf \
        iperf3 && \
    apt-get autoremove -y && \
    apt-get autoclean && \
    rm -rf /var/lib/apt/lists/*

#RUN mkdir -p /etc/apt/keyrings
#RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
#    NODE_MAJOR=20 && \
#    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list && \
#    apt-get update && apt install nodejs -y

RUN update-ca-certificates

COPY --from=builder /open5gs/install/bin /open5gs/install/bin
COPY --from=builder /open5gs/install/etc /open5gs/install/etc
COPY --from=builder /open5gs/install/lib /open5gs/install/lib
#COPY --from=builder /open5gs/webui /open5gs/webui
COPY --from=builder /open5gs/misc/db /open5gs/misc/db

# Copy License Files (runtime too)
COPY license/libLwsLicenseCheck.so /usr/lib64/
RUN chmod 777 /usr/lib64/libLwsLicenseCheck.so

# Refresh linker
RUN ldconfig

# Set the working directory to open5gs
WORKDIR /open5gs

COPY open5gs_init.sh /

# Self-heal line endings: a CRLF shebang (from Windows-edited/synced sources) makes
# the kernel look for "/bin/bash\r" and the container dies at startup with
# "exec /open5gs_init.sh: no such file or directory". Strip CRs at build time.
RUN sed -i 's/\r$//' /open5gs_init.sh && chmod +x /open5gs_init.sh

CMD ["/open5gs_init.sh"]
