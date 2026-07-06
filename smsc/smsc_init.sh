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

[ ${#MNC} == 3 ] && IMS_DOMAIN="ims.mnc${MNC}.mcc${MCC}.3gppnetwork.org" || IMS_DOMAIN="ims.mnc0${MNC}.mcc${MCC}.3gppnetwork.org"

mkdir -p /etc/kamailio_smsc
cp /mnt/smsc/smsc.cfg /etc/kamailio_smsc
cp /mnt/smsc/kamailio_smsc.cfg /etc/kamailio_smsc

while ! mysqladmin ping -h ${MYSQL_IP} --silent; do
	sleep 5;
done

# Sleep until permissions are set
sleep 10;

# Create SMSC database, populate tables and grant privileges.
# Keep this idempotent: dropping the database on every restart can block behind
# existing DB sessions and leave Kamailio unbound during readiness tests.
mysql -u root -h ${MYSQL_IP} -e "CREATE DATABASE IF NOT EXISTS smsc;"

SMS_SCHEMA_READY=`mysql -u root -h ${MYSQL_IP} -s -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='smsc' AND table_name IN ('messages','dialplan','presentity');"`
if [[ "$SMS_SCHEMA_READY" -lt 3 ]]
then
	mysql --force -u root -h ${MYSQL_IP} smsc < /usr/local/src/kamailio/utils/kamctl/mysql/standard-create.sql
	mysql --force -u root -h ${MYSQL_IP} smsc < /mnt/smsc/smsc-create.sql
	mysql --force -u root -h ${MYSQL_IP} smsc < /usr/local/src/kamailio/utils/kamctl/mysql/dialplan-create.sql
	mysql --force -u root -h ${MYSQL_IP} smsc < /usr/local/src/kamailio/utils/kamctl/mysql/presence-create.sql
fi
# Store-and-forward: ALWAYS ensure the pending_ue table exists, even on a
# PRE-EXISTING smsc DB. The block above only runs smsc-create.sql when the base
# schema is absent, so a DB provisioned before this feature was added would never
# get pending_ue -> the offline store-and-forward fails with repeated
# "Table 'smsc.pending_ue' doesn't exist (1146)" and the reset/USER_ONLINE flush
# never works. CREATE ... IF NOT EXISTS is idempotent and safe on every start
# (the persistent MySQL volume means a rebuild/reboot alone will NOT create it).
mysql -u root -h ${MYSQL_IP} smsc -e "CREATE TABLE IF NOT EXISTS pending_ue (callee VARCHAR(64) NOT NULL, UNIQUE KEY unique_callee (callee));"
mysql -u root -h ${MYSQL_IP} -e "CREATE USER IF NOT EXISTS 'smsc'@'%' IDENTIFIED WITH mysql_native_password BY 'heslo';"
mysql -u root -h ${MYSQL_IP} -e "CREATE USER IF NOT EXISTS 'smsc'@'$SMSC_IP' IDENTIFIED WITH mysql_native_password BY 'heslo';"
mysql -u root -h ${MYSQL_IP} -e "GRANT ALL ON smsc.* TO 'smsc'@'%';"
mysql -u root -h ${MYSQL_IP} -e "GRANT ALL ON smsc.* TO 'smsc'@'$SMSC_IP';"
mysql -u root -h ${MYSQL_IP} -e "FLUSH PRIVILEGES;"

sed -i 's|SMSC_IP|'$SMSC_IP'|g' /etc/kamailio_smsc/smsc.cfg
sed -i 's|IMS_DOMAIN|'$IMS_DOMAIN'|g' /etc/kamailio_smsc/smsc.cfg
sed -i 's|MYSQL_IP|'$MYSQL_IP'|g' /etc/kamailio_smsc/smsc.cfg
sed -i 's|DOCKER_HOST_IP|'$DOCKER_HOST_IP'|g' /etc/kamailio_smsc/smsc.cfg

mkdir -p /var/run/kamailio_smsc
rm -f /kamailio_smsc.pid

# IMS log capture - writes to ./log/smsc.log on the host.
# Docker logs are preserved via process substitution; no persistent FIFO is
# created in /tmp. Set IMS_LOG_ENABLED=false in .env to disable host log teeing.
IMS_LOG_DIR="/open5gs/install/var/log/open5gs"
if [ "${IMS_LOG_ENABLED:-true}" = "true" ]; then
    mkdir -p "$IMS_LOG_DIR"
    exec > >(tee -a "${IMS_LOG_DIR}/smsc.log") 2>&1
fi
exec kamailio -f /etc/kamailio_smsc/kamailio_smsc.cfg -P /kamailio_smsc.pid -DD -E -e "$@"

# Sync docker time
#ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

