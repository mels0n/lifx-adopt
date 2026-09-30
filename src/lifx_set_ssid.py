#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Provision a factory-reset LIFX bulb onto a WiFi network.

Sends a LIFX SetAccessPoint packet (message type 305) to a bulb that is
broadcasting its own open setup AP. The host must ALREADY be associated with
that AP; this script does not touch the radio. The bulb answers on
172.16.0.1:56700 over TLS.

Derived from onboard.py in https://github.com/tserong/lifx-hacks
(Copyright Tim Serong, AGPL-3.0). This file is therefore distributed under the
AGPL-3.0; see LICENSE-AGPL-3.0 next to it. The rest of this repository is MIT.

SetAccessPoint is reverse engineered and undocumented; it is absent from
LIFX's official LAN protocol spec. Upstream tested it on LIFX Original and
Color 1000 (firmware 1.22). It has also been confirmed on firmware 3.90 (LIFX
Mini D).

Differences from the original:
  * TLS floor lowered to TLSv1 on THIS CONTEXT ONLY. Bulbs speak TLS 1.0;
    OpenSSL 3.x refuses it by default. The upstream advice is to edit
    /etc/ssl/openssl.cnf, which would weaken TLS for the whole host.
  * Socket timeouts, so a silent bulb cannot hang the caller forever.
  * Meaningful exit codes for the wrapper to branch on.
  * Packet built from named fields instead of a byte literal, with a
    self-check against the known-good original bytes.
  * The bulb's StateAccessPoint reply is parsed and used as the success signal.
  * The PSK is read from the LIFX_PSK environment variable, never from argv
    (argv is world-readable in /proc and in `ps`), and is never printed.

Usage: LIFX_PSK=... lifx_set_ssid.py <ssid> [bulb_ip]

Environment:
  LIFX_PSK       WiFi passphrase to give the bulb (required; may be empty for
                 an open network when LIFX_SECURITY=1)
  LIFX_SECURITY  security protocol code, default 5 (WPA2 AES PSK):
                 1=OPEN 2=WEP_PSK 3=WPA_TKIP_PSK 4=WPA_AES_PSK
                 5=WPA2_AES_PSK 6=WPA2_TKIP_PSK 7=WPA2_MIXED_PSK

Exit codes:
  0  bulb confirmed the new SSID (StateAccessPoint echoed it back)
  1  usage error
  2  could not reach / TLS-handshake the bulb
  3  packet sent but no response
  4  responded, but not with a matching StateAccessPoint
"""

import os
import socket
import ssl
import struct
import sys
import warnings

# TLSv1 is deprecated in Python's ssl module and warns on every use. The bulbs
# speak nothing newer, so keep the log readable.
warnings.filterwarnings("ignore", category=DeprecationWarning)

LIFX_PORT = 56700
BULB_AP_IP = "172.16.0.1"
CONNECT_TIMEOUT = 10
RESPONSE_TIMEOUT = 15

MSG_SET_ACCESS_POINT = 305
MSG_STATE_ACCESS_POINT = 308
HEADER_LEN = 36

# WifiInterface
IFACE_SOFT_AP = 1
IFACE_STATION = 2

SECURITY_WPA2_AES_PSK = 5

# First 36 bytes of the original lifx-hacks packet, used as a regression
# guard on the builder below.
_ORIGINAL_HEADER = (
    bytes([0x86, 0x00, 0x00, 0x34]) + bytes(28) + bytes([0x31, 0x01, 0x00, 0x00])
)


def build_set_access_point(ssid, password, security=SECURITY_WPA2_AES_PSK):
    """Return the 134-byte SetAccessPoint frame."""
    payload = (
        bytes([IFACE_STATION])
        + ssid.encode("utf-8")[:32].ljust(32, b"\x00")
        + password.encode("utf-8")[:64].ljust(64, b"\x00")
        + bytes([security])
    )
    size = HEADER_LEN + len(payload)

    header = struct.pack("<HHI", size, 0x3400, 0)  # size | proto+flags | source
    header += bytes(8)                             # target: all-zero = broadcast
    header += bytes(6)                             # reserved
    header += bytes([0])                           # res_required / ack_required
    header += bytes([0])                           # sequence
    header += bytes(8)                             # reserved (timestamp)
    header += struct.pack("<HH", MSG_SET_ACCESS_POINT, 0)

    assert len(header) == HEADER_LEN, "header is %d bytes" % len(header)
    assert header == _ORIGINAL_HEADER, "header drifted from known-good bytes"

    frame = header + payload
    assert len(frame) == 134, "frame is %d bytes" % len(frame)
    return frame


def parse_state_access_point(resp):
    """Pull (msg_type, bulb_mac, wifi_interface, ssid) out of a bulb reply.

    A successful SetAccessPoint is answered with StateAccessPoint (308) whose
    payload echoes the SSID the bulb has just stored. That echo is the most
    reliable success signal available, far better than watching for the setup
    AP to disappear: `iw scan dump` serves a cached BSS table that keeps
    reporting the AP for tens of seconds after it is gone.

    Returns None if the response is too short to be a LIFX frame.
    """
    if len(resp) < HEADER_LEN + 33:
        return None
    msg_type = int.from_bytes(resp[32:34], "little")
    mac = ":".join("%02x" % b for b in resp[8:14])
    iface = resp[36]
    ssid = resp[37:69].rstrip(b"\x00").decode("utf-8", "replace")
    return msg_type, mac, iface, ssid


def legacy_tls_context():
    """TLS context that will talk to a LIFX bulb's ancient stack.

    Scoped to this connection. Nothing here changes host TLS policy.
    """
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    # Must precede minimum_version: SECLEVEL=0 re-enables the old ciphers
    # and key sizes that OpenSSL 3.x drops by default.
    try:
        ctx.set_ciphers("DEFAULT@SECLEVEL=0")
    except ssl.SSLError:
        ctx.set_ciphers("ALL:@SECLEVEL=0")

    ctx.minimum_version = ssl.TLSVersion.TLSv1

    # OpenSSL 3.x refuses renegotiation with servers that lack RFC 5746.
    if hasattr(ssl, "OP_LEGACY_SERVER_CONNECT"):
        ctx.options |= ssl.OP_LEGACY_SERVER_CONNECT

    return ctx


def main(argv):
    if len(argv) not in (2, 3):
        print("Usage: LIFX_PSK=... %s <ssid> [bulb_ip]" % argv[0], file=sys.stderr)
        return 1

    ssid = argv[1]
    bulb_ip = argv[2] if len(argv) == 3 else BULB_AP_IP
    password = os.environ.get("LIFX_PSK")

    if not ssid:
        print("ssid must not be empty", file=sys.stderr)
        return 1
    if password is None:
        print("LIFX_PSK is not set in the environment", file=sys.stderr)
        return 1

    try:
        security = int(os.environ.get("LIFX_SECURITY", SECURITY_WPA2_AES_PSK))
    except ValueError:
        print("LIFX_SECURITY must be an integer 1-7", file=sys.stderr)
        return 1
    if not 1 <= security <= 7:
        print("LIFX_SECURITY must be an integer 1-7", file=sys.stderr)
        return 1

    packet = build_set_access_point(ssid, password, security)
    # Deliberately does not log the PSK.
    print("target=%s:%d ssid=%s security=%d bytes=%d"
          % (bulb_ip, LIFX_PORT, ssid, security, len(packet)))

    ctx = legacy_tls_context()
    raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    raw.settimeout(CONNECT_TIMEOUT)

    try:
        sock = ctx.wrap_socket(raw)
    except ssl.SSLError as exc:
        print("TLS setup failed: %s" % exc, file=sys.stderr)
        raw.close()
        return 2

    try:
        try:
            sock.connect((bulb_ip, LIFX_PORT))
        except ssl.SSLError as exc:
            print("TLS handshake failed (bulb may be a generation that no "
                  "longer accepts SetAccessPoint): %s" % exc, file=sys.stderr)
            return 2
        except (socket.timeout, OSError) as exc:
            print("connect to %s:%d failed: %s" % (bulb_ip, LIFX_PORT, exc),
                  file=sys.stderr)
            return 2

        print("connected, sending SetAccessPoint")
        sock.sendall(packet)

        sock.settimeout(RESPONSE_TIMEOUT)
        try:
            response = sock.recv(1024)
        except socket.timeout:
            print("no response within %ds" % RESPONSE_TIMEOUT, file=sys.stderr)
            return 3
        except OSError as exc:
            print("read failed: %s" % exc, file=sys.stderr)
            return 3

        if not response:
            print("bulb closed the connection without replying", file=sys.stderr)
            return 3

        parsed = parse_state_access_point(response)
        if parsed is None:
            print("response too short to parse (%d bytes): %s"
                  % (len(response), response.hex()), file=sys.stderr)
            return 4

        msg_type, mac, iface, echoed = parsed
        print("reply type=%d interface=%d ssid=%r" % (msg_type, iface, echoed))

        if msg_type != MSG_STATE_ACCESS_POINT:
            print("expected StateAccessPoint (%d), got %d"
                  % (MSG_STATE_ACCESS_POINT, msg_type), file=sys.stderr)
            return 4

        if echoed != ssid:
            print("bulb echoed %r but we asked for %r" % (echoed, ssid),
                  file=sys.stderr)
            return 4

        if iface != IFACE_STATION:
            print("bulb reports interface %d, expected STATION (%d)"
                  % (iface, IFACE_STATION), file=sys.stderr)
            return 4

        print("CONFIRMED: bulb stored ssid %r and switched to STATION" % ssid)
        return 0
    finally:
        try:
            sock.close()
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main(sys.argv))
