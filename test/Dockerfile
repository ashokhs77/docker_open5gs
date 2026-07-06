FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_NO_CACHE_DIR=1
ENV PYTHONDONTWRITEBYTECODE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    sip-tester \
    curl \
    jq \
    dnsutils \
    netcat-openbsd \
    iproute2 \
    iperf3 \
    tcpdump \
    bash \
    docker.io \
    mysql-client \
    libsctp1 \
    lksctp-tools \
    util-linux \
    python3 \
    python3-pip \
    && pip3 install --no-cache-dir pysctp cryptography pycrate && \
    apt-get purge -y --auto-remove python3-pip && \
    rm -rf /var/lib/apt/lists/* /root/.cache /tmp/*

# Copy test framework
COPY lib/ /opt/test/lib/
COPY features/ /opt/test/features/
COPY scenarios/ /opt/test/scenarios/
COPY ue_sim/ /opt/test/ue_sim/
COPY run_tests.sh /opt/test/
COPY provision_subscribers.sh /opt/test/

RUN find /opt/test -type f -name "*.sh" -exec sed -i 's/\r$//' {} + \
    && chmod +x /opt/test/*.sh /opt/test/lib/*.sh /opt/test/features/*.sh

WORKDIR /opt/test

ENTRYPOINT ["/opt/test/run_tests.sh"]
