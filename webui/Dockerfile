FROM node:20-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        git && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --recursive https://github.com/ashokhs77/open5gs /open5gs && \
    cd /open5gs && \
    git checkout ca0a9b3b65f90c78f91a0dc48845eddef3af3a1b

WORKDIR /open5gs/webui

RUN npm ci

COPY webui_init.sh /
RUN chmod +x /webui_init.sh

EXPOSE 9999/tcp

CMD ["/webui_init.sh"]
