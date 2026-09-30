import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import lifx_set_ssid as m  # noqa: E402

SSID = "ExampleNet"
PSK = "example-passphrase"


def state_access_point_frame(mac, ssid, iface=m.IFACE_STATION):
    """A 102-byte StateAccessPoint reply shaped like the one a real bulb sends.

    size=102 | proto 0x5400 | ... | target mac | ... | type 308 | ... |
    interface byte | 32-byte SSID | zero padding
    """
    frame = bytearray(102)
    frame[0:2] = (102).to_bytes(2, "little")
    frame[2:4] = bytes([0x00, 0x54])
    frame[8:14] = bytes.fromhex(mac)
    frame[32:34] = m.MSG_STATE_ACCESS_POINT.to_bytes(2, "little")
    frame[36] = iface
    frame[37:69] = ssid.encode().ljust(32, b"\x00")
    return bytes(frame)


class BuildSetAccessPoint(unittest.TestCase):
    def test_length_and_type(self):
        frame = m.build_set_access_point(SSID, PSK)
        self.assertEqual(len(frame), 134)
        self.assertEqual(int.from_bytes(frame[0:2], "little"), 134)
        self.assertEqual(int.from_bytes(frame[32:34], "little"), 305)

    def test_payload_layout(self):
        frame = m.build_set_access_point(SSID, PSK, security=5)
        self.assertEqual(frame[36], m.IFACE_STATION)
        self.assertEqual(frame[37:69], SSID.encode().ljust(32, b"\x00"))
        self.assertEqual(frame[69:133], PSK.encode().ljust(64, b"\x00"))
        self.assertEqual(frame[133], 5)

    def test_long_values_are_truncated(self):
        frame = m.build_set_access_point("s" * 40, "p" * 80)
        self.assertEqual(len(frame), 134)
        self.assertEqual(frame[37:69], b"s" * 32)
        self.assertEqual(frame[69:133], b"p" * 64)


class ParseStateAccessPoint(unittest.TestCase):
    def test_confirming_reply(self):
        reply = state_access_point_frame("001122334455", SSID)
        self.assertEqual(
            m.parse_state_access_point(reply),
            (308, ":".join(["00", "11", "22", "33", "44", "55"]), m.IFACE_STATION, SSID),
        )

    def test_soft_ap_interface_is_reported(self):
        reply = state_access_point_frame("001122334455", SSID, iface=m.IFACE_SOFT_AP)
        self.assertEqual(m.parse_state_access_point(reply)[2], m.IFACE_SOFT_AP)

    def test_short_reply_returns_none(self):
        self.assertIsNone(m.parse_state_access_point(b"\x00" * 40))
        self.assertIsNone(m.parse_state_access_point(b""))


if __name__ == "__main__":
    unittest.main()
