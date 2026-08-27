#!/usr/bin/env python3
# Roaming-aware MMS routing: tracks which NIB each MSISDN is CURRENTLY
# registered on. nib_registry.conf is just a plain NIB_NUM:IP list now (no
# MSISDN ranges) -- used only to know every peer to replicate updates to.
#
# S-CSCF (any NIB) notifies its own local mmsc on every successful REGISTER
# (see scscf/nib-location-notify.sh). This listener REPLICATES that update to
# every other NIB listed in nib_registry.conf, so every NIB ends up with its
# own full, independent copy of "who is currently where" -- no single NIB
# (e.g. a subscriber's static home) has to be reachable for anyone else to
# learn where they currently are.
#
# Wire format on the LOCUPD line distinguishes the two hops so broadcasts
# don't cascade:
#   LOCUPD:<msisdn>:<ip>      -- origin, from this NIB's own S-CSCF:
#                                 store locally, then replicate to every peer
#   LOCUPD:<msisdn>:<ip>:1    -- a replica received from a peer's broadcast:
#                                 store locally only, never re-forward
import asyncio
import logging
import os
import time

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [LOCLISTEN] %(levelname)s: %(message)s'
)
log = logging.getLogger('location_listener')

REGISTRY = '/etc/mmsc/nib_registry.conf'
LOCATION_FILE = '/tmp/mms-storage/current_location.tsv'
PORT = int(os.environ.get('LOCATION_LISTENER_PORT', '7891'))
SELF_IP = os.environ.get('MMSC_IP', '')

_write_lock = asyncio.Lock()


def get_peer_ips():
    peers = set()
    try:
        with open(REGISTRY) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                parts = line.split(':')
                if len(parts) != 2:
                    continue
                _, nib_ip = parts
                if nib_ip and nib_ip != SELF_IP:
                    peers.add(nib_ip)
    except OSError as e:
        log.error(f"Cannot read {REGISTRY}: {e}")
    return peers


async def upsert_location(msisdn, current_nib_ip):
    async with _write_lock:
        rows = {}
        try:
            with open(LOCATION_FILE) as f:
                for line in f:
                    parts = line.rstrip('\n').split('\t')
                    if len(parts) >= 2:
                        rows[parts[0]] = parts
        except FileNotFoundError:
            pass

        rows[msisdn] = [msisdn, current_nib_ip, str(int(time.time()))]

        os.makedirs(os.path.dirname(LOCATION_FILE), exist_ok=True)
        tmp_path = LOCATION_FILE + '.tmp'
        with open(tmp_path, 'w') as f:
            for row in rows.values():
                f.write('\t'.join(row) + '\n')
        os.replace(tmp_path, LOCATION_FILE)


async def send_replica(peer_ip, msisdn, reporting_ip):
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(peer_ip, PORT), timeout=2
        )
        writer.write(f"LOCUPD:{msisdn}:{reporting_ip}:1\n".encode())
        await writer.drain()
        writer.close()
        return True
    except Exception as e:
        log.warning(f"Replica to {peer_ip} failed for {msisdn}: {e} (it'll catch up on the next registration)")
        return False


async def broadcast_to_peers(msisdn, reporting_ip):
    peers = get_peer_ips()
    if not peers:
        return
    results = await asyncio.gather(
        *(send_replica(peer, msisdn, reporting_ip) for peer in peers)
    )
    ok = sum(1 for r in results if r)
    log.info(f"Broadcast MSISDN {msisdn} -> {reporting_ip} to {ok}/{len(peers)} peers")


async def handle_client(reader, writer):
    try:
        data = await asyncio.wait_for(reader.readline(), timeout=2)
    except asyncio.TimeoutError:
        data = b''
    writer.close()

    line = data.decode(errors='replace').strip()
    if not line.startswith('LOCUPD:'):
        return

    parts = line.split(':')
    if len(parts) == 3:
        _, msisdn, reporting_ip = parts
        is_replica = False
    elif len(parts) == 4:
        _, msisdn, reporting_ip, _ = parts
        is_replica = True
    else:
        log.warning(f"Malformed location update: {line!r}")
        return

    msisdn = ''.join(c for c in msisdn if c.isdigit())
    if not msisdn or not reporting_ip:
        return

    await upsert_location(msisdn, reporting_ip)

    if is_replica:
        log.info(f"MSISDN {msisdn} is now at {reporting_ip} (replica)")
    else:
        log.info(f"MSISDN {msisdn} is now at {reporting_ip} (origin)")
        await broadcast_to_peers(msisdn, reporting_ip)


async def main():
    os.makedirs(os.path.dirname(LOCATION_FILE), exist_ok=True)
    server = await asyncio.start_server(handle_client, '0.0.0.0', PORT)
    log.info(f"Location listener bound on 0.0.0.0:{PORT} (self={SELF_IP})")
    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    asyncio.run(main())
