#!/usr/bin/env python3
"""
5G SA only: deliver Kannel's MMS notification SMS (WAP push) over SMS-over-IMS.

4G sends these through OsmoMSC -> SGs -> MME. 5G SA has no SGs, so kannel_5g.conf
points its HTTP smsc (system-type generic) here instead:

    http://127.0.0.1:13050/send?to=%p&from=%P&coding=%c&udh=%u&data=%b

(in Kannel's URL codes %p is the RECEIVER and %P the SENDER). We wrap Kannel's UDH +
binary payload in an SMS-DELIVER (TS 23.040) inside an RP-DATA (TS 24.011) and hand
the hex to the SMSC's xhttp input (?to=..&rpdu=..), which sends it unchanged as
application/vnd.3gpp.sms in a SIP MESSAGE. The SMSC cannot build it itself: Kamailio
smsops only encodes GSM-7/UCS2 text, with no 8-bit data and no port-addressing UDH.

Plain 7-bit text without UDH goes to the SMSC's normal text input instead.
Kannel's generic type only checks the reply BODY: "Sent." = success,
"TEMPFAIL" = retry (status-success-regex / status-tempfail-regex in kannel_5g.conf).
"""
import itertools
import os
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = ("127.0.0.1", int(os.environ.get("WAP_PUSH_HELPER_PORT", "13050")))
SMSC_URL = "http://%s:7090/" % os.environ["SMSC_IP"]

_mr = itertools.count(1)
_mr_lock = threading.Lock()


def log(msg):
    print("wap_push_helper: " + msg, flush=True)


def bcd(digits):
    """Semi-octet (swapped BCD) digits, padded with F."""
    if len(digits) % 2:
        digits += "F"
    return bytes(int(digits[i + 1] + digits[i], 16) for i in range(0, len(digits), 2))


def address(digits, length_in_digits):
    """Address field. TP-OA counts digits, RP-OA counts the octets that follow."""
    body = b"\x81" + bcd(digits)  # TON unknown, NPI ISDN: shown as dialled
    return bytes([len(digits) if length_in_digits else len(body)]) + body


def scts():
    """TP-SCTS in UTC, timezone 0."""
    t = time.gmtime()
    vals = (t.tm_year % 100, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec, 0)
    return bytes(int(("%02d" % v)[::-1], 16) for v in vals)


def rp_data(sender, dcs, udh, data):
    if udh and udh[0] != len(udh) - 1:
        udh = bytes([len(udh)]) + udh  # make sure the UDH carries its length octet
    ud = udh + data
    if len(ud) > 140:
        raise ValueError("user data is %d octets, max 140" % len(ud))
    first = 0x04 | (0x40 if udh else 0)  # SMS-DELIVER, no more messages, UDHI
    tpdu = (bytes([first]) + address(sender, True) + bytes([0x00, dcs]) + scts()
            + bytes([len(ud)]) + ud)
    with _mr_lock:
        mr = next(_mr) % 256
    # RP-DATA network->MS: MTI 1, MR, RP-OA (originator, as the SMSC's own MT path
    # does), empty RP-DA, RP-UD.
    return bytes([0x01, mr]) + address(sender, False) + b"\x00" + bytes([len(tpdu)]) + tpdu


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        p = {}
        for kv in query.split("&"):
            k, _, v = kv.partition("=")
            p[k] = urllib.parse.unquote_to_bytes(v.replace("+", "%20"))
        to = p.get("to", b"").decode("ascii", "replace").lstrip("+")
        sender = p.get("from", b"").decode("ascii", "replace").lstrip("+")
        if not sender.isdigit():
            sender = "0"
        try:
            coding = int(p.get("coding", b"-1") or b"-1")
        except ValueError:
            coding = -1
        udh, data = p.get("udh", b""), p.get("data", b"")

        if not to.isdigit():
            return self.reply("PERMFAIL bad to\n")
        try:
            if not udh and coding in (-1, 0):
                kind = "text"
                args = {"msisdn": sender, "to": to, "text": data.decode("latin-1")}
            else:
                kind = "binary"
                dcs = 0x08 if coding == 2 else 0x04  # UCS2 or 8-bit data
                args = {"to": to, "rpdu": rp_data(sender, dcs, udh, data).hex()}
        except ValueError as e:
            log("refused for %s: %s" % (to, e))
            return self.reply("PERMFAIL %s\n" % e)

        try:
            with urllib.request.urlopen(SMSC_URL + "?" + urllib.parse.urlencode(args),
                                        timeout=5) as r:
                ok = 200 <= r.status < 300
        except Exception as e:  # SMSC down or refused: let Kannel retry
            log("SMSC request failed for %s: %s" % (to, e))
            ok = False
        log("%s SMS to %s (udh %d B, data %d B): %s"
            % (kind, to, len(udh), len(data), "sent" if ok else "TEMPFAIL"))
        self.reply("Sent.\n" if ok else "TEMPFAIL\n")

    def reply(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, fmt, *args):
        pass  # one line per message is logged in do_GET


if __name__ == "__main__":
    log("listening on %s:%d, SMSC %s" % (LISTEN[0], LISTEN[1], SMSC_URL))
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
