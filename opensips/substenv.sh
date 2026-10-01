#!/bin/bash
# OpenSIPS config preprocessor (invoked via `opensips -p /etc/opensips/substenv.sh`):
# envsubst expands ${VAR} from the container env, then m4 expands global.m4.
# IMS_DOMAIN is not in .env, so derive it from MCC/MNC like the *_init.sh scripts
# do (MNC zero-padded to 3 digits) and export it for envsubst.
[ ${#MNC} == 3 ] && export IMS_DOMAIN="ims.mnc${MNC}.mcc${MCC}.3gppnetwork.org" || export IMS_DOMAIN="ims.mnc0${MNC}.mcc${MCC}.3gppnetwork.org"

envsubst "$(printf '${%s} ' $(env | cut -d'=' -f1))" | m4 /etc/opensips/global.m4 -
