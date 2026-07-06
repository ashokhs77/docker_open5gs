FROM ubuntu:jammy AS builder

ENV DEBIAN_FRONTEND=noninteractive
ARG FREESWITCH_COMMIT=dd23170bb1608f9840d3e006f68c57bee0812c3e

RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    build-essential \
    ca-certificates \
    cmake \
    git \
    libavformat-dev \
    libcurl4-openssl-dev \
    libedit-dev \
    libjpeg-dev \
    libldns-dev \
    liblua5.2-0 \
    liblua5.2-dev \
    libopencore-amrnb-dev \
    libopencore-amrwb-dev \
    libopus-dev \
    libpcre2-dev \
    libpcre3-dev \
    libpq-dev \
    libsndfile1-dev \
    libspeexdsp-dev \
    libsqlite3-dev \
    libssl-dev \
    libswscale-dev \
    libtiff5-dev \
    libtool \
    libtool-bin \
    libvo-amrwbenc-dev \
    libxml2-dev \
    pkg-config \
    unixodbc-dev \
    unzip \
    uuid-dev \
    wget \
    yasm \
    zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

# libks/signalwire-c CMake derives package metadata from reachable Git tags.
# Keep commit/tag history in the builder only; /usr/local/src is removed below.
RUN git clone --filter=blob:none https://github.com/signalwire/libks.git /usr/local/src/libks && \
    cd /usr/local/src/libks && \
    cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local . && \
    make -j"$(nproc)" && \
    make install && \
    ldconfig

RUN git clone --filter=blob:none https://github.com/signalwire/signalwire-c.git /usr/local/src/signalwire-c && \
    cd /usr/local/src/signalwire-c && \
    cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local . && \
    make -j"$(nproc)" && \
    make install && \
    ldconfig

RUN git clone --depth 1 https://github.com/freeswitch/sofia-sip.git /usr/local/src/sofia-sip && \
    cd /usr/local/src/sofia-sip && \
    ./bootstrap.sh && \
    ./configure && \
    make -j"$(nproc)" && \
    make install && \
    ldconfig

RUN git clone --depth 1 https://github.com/freeswitch/spandsp.git /usr/local/src/spandsp && \
    cd /usr/local/src/spandsp && \
    ./bootstrap.sh && \
    ./configure && \
    make -j"$(nproc)" && \
    make install && \
    ldconfig

RUN git init /usr/local/src/freeswitch && \
    cd /usr/local/src/freeswitch && \
    git remote add origin https://github.com/Shreyas-B-Aradhya/freeswitch && \
    git fetch --depth 1 origin "$FREESWITCH_COMMIT" && \
    git checkout FETCH_HEAD

WORKDIR /usr/local/src/freeswitch

RUN cp /usr/include/opencore-amrnb/interf_enc.h src/mod/codecs/mod_amr/ && \
    cp /usr/include/opencore-amrnb/interf_dec.h src/mod/codecs/mod_amr/ && \
    cp /usr/include/opencore-amrwb/dec_if.h src/mod/codecs/mod_amrwb/ && \
    cp /usr/include/vo-amrwbenc/enc_if.h src/mod/codecs/mod_amrwb/

# Install prompts/MOH at build time; runtime containers run without internet.
RUN ./bootstrap.sh && \
    sed -i 's/#\(codecs\/mod_amrwb\)/\1/g' modules.conf && \
    ./configure && \
    make -j"$(nproc)" && \
    make install sounds-install moh-install && \
    ldconfig

RUN rm -rf \
    /usr/local/src \
    /usr/local/include \
    /usr/local/lib/cmake \
    /usr/local/lib/pkgconfig \
    /usr/local/share/man && \
    find /usr/local -type f \( -name '*.a' -o -name '*.la' \) -delete && \
    (find /usr/local -type f \( -path '*/bin/*' -o -path '*/lib/*' -o -path '*/mod/*.so' \) -exec strip --strip-unneeded {} + 2>/dev/null || true) && \
    find /usr/local/freeswitch -type f -name '*.o' -delete

FROM ubuntu:jammy

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH=/usr/local/lib

# Runtime image intentionally excludes git, wget, compilers, headers, and sources.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libavformat58 \
    libcurl4 \
    libedit2 \
    libjpeg-turbo8 \
    libldns3 \
    liblua5.2-0 \
    libopencore-amrnb0 \
    libopencore-amrwb0 \
    libopus0 \
    libpcre2-8-0 \
    libpcre3 \
    libpq5 \
    libsndfile1 \
    libspeexdsp1 \
    libsqlite3-0 \
    libswscale5 \
    libtiff5 \
    libuuid1 \
    libvo-amrwbenc0 \
    libxml2 \
    unixodbc \
    zlib1g && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local /usr/local
COPY freeswitch_init.sh /freeswitch_init.sh

RUN ldconfig && chmod +x /freeswitch_init.sh

EXPOSE 8021/tcp
EXPOSE 5090/tcp 5090/udp 5092/tcp 5092/udp
EXPOSE 5066/tcp
EXPOSE 7443/tcp
EXPOSE 8081/tcp 8082/tcp
EXPOSE 64535-65535/udp
EXPOSE 16384-32768/udp

CMD ["/freeswitch_init.sh"]

