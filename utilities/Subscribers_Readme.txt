ADDING AND DELETING SUBSCRIBERS WITH SCRIPTS
============================================

Two scripts add or delete SIM subscribers in one step, from one list file.

  subscriber.sh         -> adds to PyHSS (AUC + SUBSCRIBER + IMS_SUBSCRIBER)
                           needed for IMS (VoLTE/VoNR) and 4G
  mongo_subscriber.sh   -> adds to Open5GS MongoDB (the WebUI subscribers)
                           needed for 5G

For a 5G VoNR SIM, run BOTH.


FILES
-----

Keep these three files in the same folder (for example pyhss/ or utilities/):

  subscriber.sh
  mongo_subscriber.sh
  subscribers_list

The folder must be one level below the docker_open5gs folder, because
subscriber.sh reads MCC/MNC from ../.env

Run the scripts on the docker host (the EPC machine), where PyHSS and MongoDB
are running.


BEFORE THE FIRST RUN
--------------------

APN IDs 1 (internet) and 2 (ims) must exist in PyHSS. This is done once, see
"Provisioning of SIM information in pyHSS" step 2 in the main README.md.


1. PUT THE SUBSCRIBERS IN subscribers_list
------------------------------------------

One subscriber per line: IMSI, then MSISDN. Lines starting with # are ignored.

  # IMSI           MSISDN
  001010100008004  9876548004
  001010100008005  9876548005

A comma instead of the space also works (001010100008004,9876548004).

The file name is subscribers_list, with an "s". Each script prints
"Using <file>" first, so you can see which file it read.


2. ADD THEM
-----------

  bash subscriber.sh            # PyHSS (IMS + 4G)
  bash mongo_subscriber.sh      # MongoDB (5G)

Subscribers that are already there are skipped. So you can add new lines to
the list and run the scripts again.

Example output:

  Using /home/.../utilities/subscribers_list
  OK   added 001010100008005 msisdn=9876548005: AUC(auc_id=23) SUBSCRIBER(subscriber_id=23) IMS_SUBSCRIBER(ims_subscriber_id=23)  [ims.mnc001.mcc001.3gppnetwork.org]
  SKIP 001010100008004 already in PyHSS: AUC(auc_id=1) SUBSCRIBER(subscriber_id=1) IMS_SUBSCRIBER(ims_subscriber_id=1)
  Done: 1 added, 1 skipped, 0 failed

  OK     = added
  SKIP   = was already there
  ERROR  = failed, the reason is printed

- The auc_id is assigned by PyHSS. The script puts the same auc_id in the
  SUBSCRIBER entry.
- mongo_subscriber.sh first prints "OK   profile UE updated". It keeps the
  WebUI profile "UE" at the same values as the subscribers.


3. DELETE THEM
--------------

  bash subscriber.sh del            # deletes everyone in the list from PyHSS
  bash mongo_subscriber.sh del      # deletes everyone in the list from MongoDB

subscriber.sh del removes IMS_SUBSCRIBER, SUBSCRIBER and AUC, in that order.


ONE SUBSCRIBER ONLY
-------------------

  bash subscriber.sh add 001010100008006 9876548006
  bash subscriber.sh del 001010100008006
  bash subscriber.sh show 001010100008006       # what PyHSS has for this IMSI

  bash mongo_subscriber.sh add 001010100008006 9876548006
  bash mongo_subscriber.sh del 001010100008006


CHANGING A SUBSCRIBER
---------------------

The scripts never overwrite an existing subscriber. To change one, delete it
and add it again:

  bash subscriber.sh del 001010100008006
  bash subscriber.sh add 001010100008006 9876548006


FIXED VALUES (SAME FOR EVERY SUBSCRIBER)
----------------------------------------

These are set at the top of each script. Edit them there.

  Ki                       5e4ab35891375d2aee812e67c309a629   (both scripts)
  OPc                      24c2d90f545ae2f7a87cacdc705a7950   (both scripts)
  AMF                      8000                               (both scripts)
  APN list / default APN   1,2 / 1                            (subscriber.sh)

Ki, OPc and AMF must be the same in both scripts. If they differ, the SIM
fails authentication.

QoS in MongoDB (set in mongo_subscriber.sh, in the JavaScript part):

  DNN                 5QI   ARP   Bandwidth
  UE total                        1 Gbps / 1 Gbps
  internet (IPv4v6)   9     8     1 Gbps / 1 Gbps
  ims (IPv4)          5     1     3850 Kbps DL / 1520 Kbps UL
  ims voice rule      1     2     MBR 128 Kbps, GBR 128 Kbps
  ims video rule      2     4     MBR 1 Mbps,   GBR 512 Kbps


IMS DOMAIN (MCC/MNC)
--------------------

subscriber.sh builds the IMS domain from MCC/MNC in .env, with the MNC padded
to 3 digits. For example, MCC=001 and MNC=01 give
ims.mnc001.mcc001.3gppnetwork.org

It is printed at the end of each "OK added" line. Nothing to set by hand.


OPTIONS
-------

  --list FILE            both scripts          use another list file
  --api URL              subscriber.sh         PyHSS API, default http://127.0.0.1:8080
  --mcc 405 --mnc 871    subscriber.sh         other PLMN than .env
  --container NAME       mongo_subscriber.sh   MongoDB container, default mongo
  profile (command)      mongo_subscriber.sh   only update the WebUI profile "UE"

"bash subscriber.sh --help" and "bash mongo_subscriber.sh --help" show the same.


COMMON PROBLEMS
---------------

Message:  SKIP ... already in ...   (for a SIM you just added to the list)
Fix:      Wrong list file. Check the "Using ..." line, and that the file is
          named subscribers_list.

Message:  cannot reach PyHSS API at ...
Fix:      PyHSS is not running, or the script is not on the docker host.
          Use --api http://<host>:8080

Message:  MongoDB container 'mongo' is not running
Fix:      Start the core, or use --container NAME.

Message:  ... is partly in PyHSS
Fix:      An earlier add stopped halfway. Run "bash subscriber.sh del <imsi>",
          then add again.

Message:  NOTE: no --mcc/--mnc and no MCC/MNC in .../.env
Fix:      The script folder is not one level below docker_open5gs. Move it,
          or use --mcc/--mnc.

Problem:  New QoS values are not used by the phone
Fix:      Turn airplane mode on and off. QoS is read when the phone starts a
          new session.
