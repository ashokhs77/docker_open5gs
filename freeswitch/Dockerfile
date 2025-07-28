FROM ubuntu:jammy as builder


ENV DEBIAN_FRONTEND=noninteractive

# Step 1: Install dependencies
RUN apt-get update && apt-get install -y \
  git cmake vim net-tools build-essential pkg-config uuid-dev zlib1g-dev libjpeg-dev libsqlite3-dev libcurl4-openssl-dev libpcre3-dev libspeexdsp-dev libldns-dev libedit-dev libtiff5-dev yasm libopus-dev libsndfile1-dev unzip libavformat-dev libswscale-dev liblua5.2-dev liblua5.2-0 cmake libpq-dev unixodbc-dev autoconf automake ntpdate libxml2-dev libpq-dev libpq5  libpcre2-dev pkg-config sngrep wget

RUN apt-get install -y libopencore-amrwb-dev  libopencore-amrwb0 libvo-amrwbenc-dev libvo-amrwbenc0
 
RUN apt-get install libopencore-amrnb-dev libopencore-amrnb0

# Step 2: Build libks
RUN git clone https://github.com/signalwire/libks.git /usr/local/src/libks && \
  cd /usr/local/src/libks && \
  cmake . && \
  make && \
  make install && \
  ldconfig

# Step 3: Build signalwire-c
RUN git clone https://github.com/signalwire/signalwire-c.git /usr/local/src/signalwire-c && \
  cd /usr/local/src/signalwire-c && \
  cmake . && \
  make && \
  make install && \
  ldconfig

# Step 4: Build sofia-sip
RUN git clone https://github.com/freeswitch/sofia-sip.git /usr/local/src/sofia-sip && \
  cd /usr/local/src/sofia-sip && \
  ./bootstrap.sh && \
  ./configure && \
  make && \
  make install && \
  ldconfig

# Step 5: Build spandsp
RUN git clone https://github.com/freeswitch/spandsp.git /usr/local/src/spandsp && \
  cd /usr/local/src/spandsp && \
  ./bootstrap.sh && \
  ./configure && \
  make && \
  make install && \
  ldconfig

# Step 6: Build FreeSWITCH from source
#RUN git clone https://github.com/Shreyas-B-Aradhya/freeswitch /usr/local/src/freeswitch
RUN git clone https://github.com/Shreyas-B-Aradhya/freeswitch /usr/local/src/freeswitch && \
    cd /usr/local/src/freeswitch  && git checkout b168a6bee9c9fd49aec32feeaad6d3508550bf4f
    #cd /usr/local/src/freeswitch  && git checkout 8aaa38d90ceb2f040916f17226df570bc3c5557e
    # cd /usr/local/src/freeswitch  && git checkout ee54173e54fd7181def97ed54931d1da80a9b5dd



WORKDIR /usr/local/src/freeswitch

# Copy over AMR files
RUN cp /usr/include/opencore-amrnb/interf_enc.h /usr/local/src/freeswitch/src/mod/codecs/mod_amr/ && \
  cp /usr/include/opencore-amrnb/interf_dec.h /usr/local/src/freeswitch/src/mod/codecs/mod_amr/ && \
  cp /usr/include/opencore-amrwb/dec_if.h /usr/local/src/freeswitch/src/mod/codecs/mod_amrwb/ && \
  cp /usr/include/vo-amrwbenc/enc_if.h /usr/local/src/freeswitch/src/mod/codecs/mod_amrwb/

RUN cd /usr/local/src/freeswitch && ./bootstrap.sh

# Add AMR WB to modules list
RUN sed -i 's/#\(codecs\/mod_amrwb\)/\1/g' modules.conf

RUN ./configure && \
  make && \
  make all install cd-sounds-install cd-moh-install && \
  ldconfig

EXPOSE 8021/tcp
EXPOSE 5090/tcp 5090/udp 5092/tcp 5092/udp
#EXPOSE 5061/tcp 5061/udp 5081/tcp 5081/udp
EXPOSE 5066/tcp
EXPOSE 7443/tcp
EXPOSE 8081/tcp 8082/tcp
EXPOSE 64535-65535/udp
EXPOSE 16384-32768/udp

COPY freeswitch_init.sh /freeswitch_init.sh
RUN chmod +x /freeswitch_init.sh
CMD ["/freeswitch_init.sh"]


