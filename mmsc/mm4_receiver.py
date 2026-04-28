#!/usr/bin/env python3
import asyncio
import subprocess
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [MM4] %(levelname)s: %(message)s'
)
log = logging.getLogger('mm4_receiver')

from aiosmtpd.controller import Controller

MBUNI_CONF   = '/tmp/mbuni.conf'
MMSFROMEMAIL = '/usr/local/mbuni/bin/mmsfromemail'

class MM4Handler:
    async def handle_DATA(self, server, session, envelope):
        mail_from = envelope.mail_from
        rcpt_tos  = envelope.rcpt_tos

        log.info(f"MM4 received: from={mail_from} to={rcpt_tos}")

        content = envelope.content
        if isinstance(content, str):
            content = content.encode('utf-8', errors='replace')

        for rcpt in rcpt_tos:
            try:
                # Flags before config file — required by get_and_set_debugs
                cmd = [MMSFROMEMAIL, '-f', mail_from, '-t', rcpt, MBUNI_CONF]
                log.info(f"Running: {' '.join(cmd)}")
                proc = subprocess.run(
                    cmd,
                    input=content,
                    capture_output=True,
                    timeout=30
                )
                if proc.returncode == 0:
                    log.info(f"mmsfromemail: delivered OK to {rcpt}")
                else:
                    log.error(f"mmsfromemail failed (rc={proc.returncode}): {proc.stderr.decode()}")
            except subprocess.TimeoutExpired:
                log.error(f"mmsfromemail timed out for {rcpt}")
            except Exception as e:
                log.error(f"Error processing MM4 message for {rcpt}: {e}")

        return '250 OK'

async def main():
    controller = Controller(
        MM4Handler(),
        hostname='0.0.0.0',
        port=25,
        decode_data=False
    )
    controller.start()
    log.info("MM4 SMTP receiver listening on port 25")
    try:
        while True:
            await asyncio.sleep(3600)
    except (KeyboardInterrupt, SystemExit):
        controller.stop()

if __name__ == '__main__':
    asyncio.run(main())
