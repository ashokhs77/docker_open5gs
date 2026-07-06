# BSD 2-Clause License
# Copyright (c) 2020-2025, Supreeth Herle
#
# Dedicated Open5GS WebUI image for 5G SA deployments.
#
# IMPORTANT: this image is built and consumed ONLY by sa-vonr-deploy.yaml.
# It is completely separate from the shared docker_open5gs base image used
# by 4G and 5G NF containers (amf, smf, upf, etc.), so adding this image
# cannot change 4G behavior.
#
# The Open5GS git SHA is pinned to match ../base/Dockerfile so that the
# WebUI schema is aligned with the NF binaries being used.

FROM node:20-bookworm-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Clone Open5GS at the same commit as base/Dockerfile and install WebUI deps.
# We only need the webui/ subtree; the rest of the repo is removed afterwards
# to keep the image small.
RUN git init /open5gs && \
    cd /open5gs && \
    git remote add origin https://github.com/ashokhs77/open5gs && \
    git fetch --depth 1 origin 142951f98a687bc1bee05d3efa33ccceeffbc21e && \
    git checkout FETCH_HEAD && \
    cd /open5gs/webui && \
    npm ci && \
    find /open5gs -mindepth 1 -maxdepth 1 -not -name webui -exec rm -rf {} + && \
    npm cache clean --force && \
    rm -rf /root/.npm /tmp/*

FROM node:20-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        iputils-ping \
        netbase \
        netcat-openbsd && \
    apt-get autoremove -y && \
    apt-get autoclean && \
    rm -rf /var/lib/apt/lists/* /root/.npm /tmp/*

COPY --from=builder /open5gs /open5gs

WORKDIR /open5gs

COPY webui_init.sh /webui_init.sh
RUN chmod +x /webui_init.sh

EXPOSE 9999/tcp

CMD ["/webui_init.sh"]

