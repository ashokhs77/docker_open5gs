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

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_NO_CACHE_DIR=1
ENV PYTHONDONTWRITEBYTECODE=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        gcc \
        git \
        libmysqlclient-dev \
        libsctp-dev \
        libsystemd-dev \
        pkg-config \
        python3-dev \
        python3-pip \
        python3-setuptools \
        python3-wheel && \
    rm -rf /var/lib/apt/lists/*

RUN git init /src/pyhss && \
    cd /src/pyhss && \
    git remote add origin https://github.com/ashokhs77/pyhss && \
    git fetch --depth 1 origin 682e6adf135a2647d2c84a4924593aa8910c79d5 && \
    git checkout FETCH_HEAD && \
    python3 -m py_compile lib/database.py && \
    python3 -m py_compile lib/diameter.py && \
    python3 -m py_compile tests/test_serving_apn_lifecycle.py && \
    python3 -m py_compile tests/test_rx_identity_resolution.py && \
    grep -Fq '[SERVING_APN_STATE] action=UPSERT' lib/database.py && \
    grep -Fq '[SERVING_APN_STATE] action=STALE_DELETE_IGNORED' lib/database.py && \
    grep -Fq '[RX_IDENTITY] source=framed-ip' lib/diameter.py && \
    grep -Fq '[RX_IDENTITY] source=subscription-id' lib/diameter.py && \
    grep -Fq 'validation=preloaded' lib/diameter.py

RUN sed -E 's/^mysqlclient([<>= ].*)?$/mysqlclient==2.1.1/' \
        /src/pyhss/requirements.txt > /tmp/pyhss-requirements.txt && \
    pip3 install --no-cache-dir --target /opt/pyhss-python \
        -r /tmp/pyhss-requirements.txt \
        pandas \
        openpyxl && \
    cd /src/pyhss && \
    PYTHONPATH=/opt/pyhss-python:/src/pyhss/lib \
        python3 -c "import runpy; runpy.run_path('tests/test_serving_apn_lifecycle.py')['test_serving_apn_atomic_lifecycle']()" && \
    PYTHONPATH=/opt/pyhss-python:/src/pyhss/lib \
        python3 -c "import runpy; runpy.run_path('tests/test_rx_identity_resolution.py')['test_rx_identity_resolution']()" && \
    find /opt/pyhss-python -type d -name '__pycache__' -prune -exec rm -rf {} +

FROM ubuntu:jammy

ENV DEBIAN_FRONTEND=noninteractive
ENV PYHSS_PYTHON_DEPS=/opt/pyhss-python
ENV PYTHONPATH=/opt/pyhss-python
ENV PYTHONDONTWRITEBYTECODE=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        default-mysql-client \
        gpg \
        libmysqlclient21 \
        libsctp1 \
        libsystemd0 \
        lsb-release \
        python3 && \
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends redis && \
    apt-get purge -y --auto-remove curl gpg lsb-release && \
    apt-get autoclean && \
    rm -rf /var/lib/apt/lists/* /root/.cache /tmp/*

COPY --from=builder /src/pyhss /pyhss
COPY --from=builder /opt/pyhss-python /opt/pyhss-python
RUN mkdir -p /pyhss/log/

WORKDIR /pyhss

CMD ["/mnt/pyhss/pyhss_init.sh"]
