#!/bin/bash

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

while ! mysqladmin ping -h ${MYSQL_IP} --silent; do
	sleep 5;
done

# Sleep until permissions are set
sleep 10;

# Create IMS HSS database user
PYHSS_USER_EXISTS=`mysql -u root -h ${MYSQL_IP} -s -N -e "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE User = 'pyhss' AND Host = '$PYHSS_IP')"`
if [[ "$PYHSS_USER_EXISTS" == 0 ]]
then
	mysql -u root -h ${MYSQL_IP} -e "CREATE USER 'pyhss'@'%' IDENTIFIED WITH mysql_native_password BY 'ims_db_pass'";
	mysql -u root -h ${MYSQL_IP} -e "CREATE USER 'pyhss'@'$PYHSS_IP' IDENTIFIED WITH mysql_native_password BY 'ims_db_pass'";
	mysql -u root -h ${MYSQL_IP} -e "GRANT ALL ON *.* TO 'pyhss'@'%'";
	mysql -u root -h ${MYSQL_IP} -e "GRANT ALL ON *.* TO 'pyhss'@'$PYHSS_IP'";
	mysql -u root -h ${MYSQL_IP} -e "FLUSH PRIVILEGES;"
fi

[ ${#MNC} == 3 ] && EPC_DOMAIN="epc.mnc${MNC}.mcc${MCC}.3gppnetwork.org" || EPC_DOMAIN="epc.mnc0${MNC}.mcc${MCC}.3gppnetwork.org"
[ ${#MNC} == 3 ] && IMS_DOMAIN="ims.mnc${MNC}.mcc${MCC}.3gppnetwork.org" || IMS_DOMAIN="ims.mnc0${MNC}.mcc${MCC}.3gppnetwork.org"

cp /mnt/pyhss/config.yaml ./
cp /mnt/pyhss/default_ifc.xml ./
cp /mnt/pyhss/default_sh_user_data.xml ./

INSTALL_PREFIX="/pyhss"

sed -i 's|PYHSS_IP|'$PYHSS_IP'|g' ./config.yaml
sed -i 's|PYHSS_BIND_PORT|'$PYHSS_BIND_PORT'|g' ./config.yaml
sed -i 's|IMS_DOMAIN|'$IMS_DOMAIN'|g' ./config.yaml
sed -i 's|OP_MCC|'$MCC'|g' ./config.yaml
sed -i 's|OP_MNC|'$MNC'|g' ./config.yaml
sed -i 's|MYSQL_IP|'$MYSQL_IP'|g' ./config.yaml
sed -i 's|INSTALL_PREFIX|'$INSTALL_PREFIX'|g' ./config.yaml

# --- Hardware-adaptive concurrency sizing -------------------------------------
# Keep the default worker counts proportional to the CPUs visible inside the
# container. A 4-CPU Lexboard therefore runs 4 HSS workers, 4 Diameter readers
# and an 8+4 SQL pool; a larger server scales up automatically. Explicit
# environment overrides remain available for controlled load testing.
_CPU_COUNT="$(nproc 2>/dev/null || echo 2)"
if ! [[ "$_CPU_COUNT" =~ ^[0-9]+$ ]] || [ "$_CPU_COUNT" -lt 1 ]; then
	_CPU_COUNT=2
fi

if [ -n "${PYHSS_HSS_SERVICE_WORKERS:-}" ]; then
	HSS_SERVICE_WORKERS="$PYHSS_HSS_SERVICE_WORKERS"
else
	HSS_SERVICE_WORKERS="$_CPU_COUNT"
	[ "$HSS_SERVICE_WORKERS" -lt 4 ] && HSS_SERVICE_WORKERS=4
	[ "$HSS_SERVICE_WORKERS" -gt 32 ] && HSS_SERVICE_WORKERS=32
fi
if ! [[ "$HSS_SERVICE_WORKERS" =~ ^[0-9]+$ ]] || [ "$HSS_SERVICE_WORKERS" -lt 1 ]; then
	echo "Invalid PYHSS_HSS_SERVICE_WORKERS='$HSS_SERVICE_WORKERS'; using CPU-derived default"
	HSS_SERVICE_WORKERS="$_CPU_COUNT"
	[ "$HSS_SERVICE_WORKERS" -lt 4 ] && HSS_SERVICE_WORKERS=4
	[ "$HSS_SERVICE_WORKERS" -gt 32 ] && HSS_SERVICE_WORKERS=32
fi

if [ -n "${PYHSS_DIAMETER_SERVICE_WORKERS:-}" ]; then
	DIAMETER_SERVICE_WORKERS="$PYHSS_DIAMETER_SERVICE_WORKERS"
else
	DIAMETER_SERVICE_WORKERS="$_CPU_COUNT"
	[ "$DIAMETER_SERVICE_WORKERS" -lt 4 ] && DIAMETER_SERVICE_WORKERS=4
	[ "$DIAMETER_SERVICE_WORKERS" -gt 32 ] && DIAMETER_SERVICE_WORKERS=32
fi
if ! [[ "$DIAMETER_SERVICE_WORKERS" =~ ^[0-9]+$ ]] || [ "$DIAMETER_SERVICE_WORKERS" -lt 1 ]; then
	echo "Invalid PYHSS_DIAMETER_SERVICE_WORKERS='$DIAMETER_SERVICE_WORKERS'; using CPU-derived default"
	DIAMETER_SERVICE_WORKERS="$_CPU_COUNT"
	[ "$DIAMETER_SERVICE_WORKERS" -lt 4 ] && DIAMETER_SERVICE_WORKERS=4
	[ "$DIAMETER_SERVICE_WORKERS" -gt 32 ] && DIAMETER_SERVICE_WORKERS=32
fi

if [ -n "${PYHSS_SQLALCHEMY_POOL_SIZE:-}" ]; then
	SQLALCHEMY_POOL_SIZE="$PYHSS_SQLALCHEMY_POOL_SIZE"
else
	SQLALCHEMY_POOL_SIZE=$((_CPU_COUNT * 2))
	[ "$SQLALCHEMY_POOL_SIZE" -lt 8 ] && SQLALCHEMY_POOL_SIZE=8
	[ "$SQLALCHEMY_POOL_SIZE" -gt 64 ] && SQLALCHEMY_POOL_SIZE=64
fi
if ! [[ "$SQLALCHEMY_POOL_SIZE" =~ ^[0-9]+$ ]] || [ "$SQLALCHEMY_POOL_SIZE" -lt 1 ]; then
	echo "Invalid PYHSS_SQLALCHEMY_POOL_SIZE='$SQLALCHEMY_POOL_SIZE'; using CPU-derived default"
	SQLALCHEMY_POOL_SIZE=$((_CPU_COUNT * 2))
	[ "$SQLALCHEMY_POOL_SIZE" -lt 8 ] && SQLALCHEMY_POOL_SIZE=8
	[ "$SQLALCHEMY_POOL_SIZE" -gt 64 ] && SQLALCHEMY_POOL_SIZE=64
fi

if [ -n "${PYHSS_SQLALCHEMY_MAX_OVERFLOW:-}" ]; then
	SQLALCHEMY_MAX_OVERFLOW="$PYHSS_SQLALCHEMY_MAX_OVERFLOW"
else
	SQLALCHEMY_MAX_OVERFLOW="$_CPU_COUNT"
	[ "$SQLALCHEMY_MAX_OVERFLOW" -lt 4 ] && SQLALCHEMY_MAX_OVERFLOW=4
	[ "$SQLALCHEMY_MAX_OVERFLOW" -gt 32 ] && SQLALCHEMY_MAX_OVERFLOW=32
fi
if ! [[ "$SQLALCHEMY_MAX_OVERFLOW" =~ ^[0-9]+$ ]]; then
	echo "Invalid PYHSS_SQLALCHEMY_MAX_OVERFLOW='$SQLALCHEMY_MAX_OVERFLOW'; using CPU-derived default"
	SQLALCHEMY_MAX_OVERFLOW="$_CPU_COUNT"
	[ "$SQLALCHEMY_MAX_OVERFLOW" -lt 4 ] && SQLALCHEMY_MAX_OVERFLOW=4
	[ "$SQLALCHEMY_MAX_OVERFLOW" -gt 32 ] && SQLALCHEMY_MAX_OVERFLOW=32
fi

echo "PyHSS concurrency sized for ${_CPU_COUNT} CPU(s): hss_service_workers=${HSS_SERVICE_WORKERS} diameter_service_workers=${DIAMETER_SERVICE_WORKERS} sqlalchemy_pool_size=${SQLALCHEMY_POOL_SIZE} sqlalchemy_max_overflow=${SQLALCHEMY_MAX_OVERFLOW}"

sed -i 's|DIAMETER_SERVICE_WORKERS|'$DIAMETER_SERVICE_WORKERS'|g' ./config.yaml
sed -i 's|SQLALCHEMY_POOL_SIZE|'$SQLALCHEMY_POOL_SIZE'|g' ./config.yaml
sed -i 's|SQLALCHEMY_MAX_OVERFLOW|'$SQLALCHEMY_MAX_OVERFLOW'|g' ./config.yaml

# Sync docker time
#ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

redis-server --daemonize yes

cd services
python3 apiService.py &
# Sleep is needed to let db be populated in a non-overlapping fashion
sleep 5
python3 diameterService.py &
# Sleep is needed to let db be populated in a non-overlapping fashion
sleep 5

echo "Starting ${HSS_SERVICE_WORKERS} PyHSS hssService worker(s)"

worker_id=1
while [ "$worker_id" -lt "$HSS_SERVICE_WORKERS" ]; do
	python3 hssService.py &
	worker_id=$((worker_id + 1))
done

exec python3 hssService.py $@
