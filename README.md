# lifx-adopt

Zero-touch re-onboarding of factory-reset LIFX bulbs, from a Linux machine with an idle WiFi radio.

## What this is

A LIFX bulb that has been hardware-reset (five power cycles) forgets your WiFi credentials and starts broadcasting its own open setup network, named like `LIFX Mini D 1a2b3c`. Normally you would join that network by hand from a laptop and push credentials at the bulb with a script. This does it for you: reset the bulb, wait a few minutes, and it rejoins your network.

This is a cleaned-up, generic version of the setup running in my home, not a copy of my live configuration. The background, including why the bulbs sit on their own VLAN and why discovery needed rethinking, is in [this write-up](https://chris.melson.us/guide/operational-architecture/blog/lifx-vlan-iot-discovery).

It only adopts bulbs that are already in setup mode. It does not fix bulbs that merely dropped off WiFi: a bulb enters setup mode only after a deliberate hardware reset, so a network blip never triggers it.

**How it works**

- **A timer runs one pass every few minutes.** A pass brings the WiFi radio up, scans for open networks whose name starts with `LIFX`, and if none are in range puts the radio straight back down. That is the no-op path and it is what runs almost every time.
- **It joins the setup network with `iw connect`.** Setup networks are open, so no `wpa_supplicant` is involved. The host takes the static address `172.16.0.2/24`; the bulb is always at `172.16.0.1` (both are fixed by LIFX). No DHCP client is needed.
- **It waits for the bulb to answer.** Association succeeding does not mean the bulb is reachable yet (ARP may not have resolved), so the script polls TCP port 56700 before sending anything.
- **It sends `SetAccessPoint` once.** `src/lifx_set_ssid.py` opens a TLS connection to the bulb and sends your SSID and passphrase in a single packet. There is no retry loop within a pass.
- **The bulb's own reply decides success.** A bulb that accepted the credentials answers with a `StateAccessPoint` frame that echoes the SSID it stored. The script exits successfully only if that frame arrives, echoes your SSID, and reports the station interface. Watching the setup network disappear is not used as the test, because `iw scan dump` serves a cached table that keeps listing a network for tens of seconds after it stops beaconing.
- **A failing bulb backs off.** Failures are counted per bulb (keyed by the setup network's BSSID). Three consecutive failures suppress that bulb for 24 hours, so a dead or unsupported bulb cannot make the radio cycle every five minutes forever.
- **The radio is always restored.** A shell `trap` puts the interface back down on any exit path, and the unit's `ExecStopPost=` does it again if the script itself was killed.
- **Two machines can cover two areas.** Install it on each and leave them uncoordinated. If both see the same bulb, whichever adopts it first removes the setup network and the other finds nothing on its next scan.

| File | Purpose |
|---|---|
| `bin/lifx-adopt.sh` | The loop: scan, join, provision, release, record |
| `src/lifx_set_ssid.py` | Builds the `SetAccessPoint` packet and parses the reply (AGPL-3.0) |
| `systemd/lifx-adopt.service` | One-shot unit, with a hard timeout and radio-down on stop |
| `systemd/lifx-adopt.timer` | Runs a pass shortly after boot, then every five minutes |
| `lifx-adopt.env.example` | Template for the root-only credentials file |
| `tests/test_lifx_set_ssid.py` | Packet build and reply parse tests |
| `docs/adr/` | Why it is built this way |

## Install

**Requirements:** Linux with systemd, root, a WiFi interface that nothing else is using, `iw`, `iproute2`, `python3` (3.7 or later), and `flock` and `timeout` from util-linux and coreutils. Debian and Ubuntu: `sudo apt install iw`.

The radio must be genuinely idle. The script brings the interface up and down and adds and flushes an address on it, so do not point it at a radio your host uses for its own connectivity. If the machine has more than one wireless interface, set `WIFI_IFACE` (see Tunables).

1. **Copy the files.**
   ```bash
   sudo mkdir -p /opt/lifx-adopt
   sudo cp -r bin src /opt/lifx-adopt/
   sudo cp systemd/lifx-adopt.service systemd/lifx-adopt.timer /etc/systemd/system/
   ```
   The paths in `lifx-adopt.service` assume `/opt/lifx-adopt`. Edit them if you install elsewhere.
2. **Add your credentials** (see Secrets below).
3. **Try it without changing anything.** A dry run scans and reports, and never joins a network:
   ```bash
   sudo DRY_RUN=1 bash /opt/lifx-adopt/bin/lifx-adopt.sh
   ```
   With a reset bulb in range you should see it listed. With none in range you should see `no LIFX setup APs in range`, and the radio should be back down afterwards (`ip link show`).
4. **Enable the timer.**
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now lifx-adopt.timer
   ```
5. **Reset a bulb** (power-cycle it five times) and wait. Follow along with:
   ```bash
   journalctl -u lifx-adopt -f
   ```

### Operating it

```bash
journalctl -u lifx-adopt -n 50 --no-pager     # what happened
systemctl list-timers lifx-adopt.timer         # when it runs next
sudo systemctl start lifx-adopt.service        # run a pass right now
sudo bash /opt/lifx-adopt/bin/lifx-adopt.sh --radio-down   # force the radio down
sudo truncate -s 0 /var/lib/lifx-adopt/state   # clear every bulb's cooldown
```

Do not use `pkill -f lifx-adopt` over SSH. The pattern also matches the SSH command line running it, and kills your own session. Signal the PID instead.

### Tunables

Set these as environment variables for a manual run, or with `systemctl edit lifx-adopt.service` (`Environment=NAME=value`) for the timer.

| Variable | Default | Meaning |
|---|---|---|
| `WIFI_IFACE` | first wireless interface | interface to use |
| `DRY_RUN` | 0 | scan and report only |
| `RSSI_FLOOR` | -75 | ignore setup networks weaker than this (dBm) |
| `MAX_PER_RUN` | 3 | bulbs handled per pass |
| `COOLDOWN_FAILS` | 3 | consecutive failures before a bulb is suppressed |
| `COOLDOWN_SECS` | 86400 | how long a suppressed bulb stays suppressed |
| `BULB_WAIT` | 25 | seconds to wait for the bulb to answer on port 56700 |
| `SCAN_SETTLE` | 8 | seconds between scan trigger and reading results |
| `CONFIG_FILE` | `/etc/lifx-adopt/lifx-adopt.env` | credentials file |

## Secrets

The one secret is your WiFi passphrase. It lives in a root-only file, never in the script:

```bash
sudo install -d -m 0755 /etc/lifx-adopt
sudo install -m 0600 -o root -g root lifx-adopt.env.example /etc/lifx-adopt/lifx-adopt.env
sudo "${EDITOR:-nano}" /etc/lifx-adopt/lifx-adopt.env
```

Set `LIFX_SSID` and `LIFX_PSK`. The script refuses to run if the file is readable by anyone other than root. It hands the passphrase to the provisioner through the environment rather than the command line, so it does not appear in `ps`, and it never logs it.

Be aware of one exposure this cannot remove. The bulb's setup network is open, so the passphrase travels over an unencrypted radio link, inside a TLS session to the bulb. The bulb's certificate is self-signed and cannot be verified, so someone already in radio range and actively impersonating the setup network could capture it. The window is a few seconds. Decide whether that is acceptable for your environment. Keeping this on a guest or IoT network passphrase, not your main one, limits the damage.

## Compatibility

`SetAccessPoint` (message type 305) is reverse-engineered and undocumented. It is not in LIFX's official LAN protocol spec, and the common libraries (`lifxlan`, `aiolifx`, `photons`) do not implement it. The original implementation is [tserong/lifx-hacks](https://github.com/tserong/lifx-hacks).

| Bulb generation | Firmware | Status |
|---|---|---|
| LIFX Original, Color 1000 | 1.22 | works (confirmed upstream) |
| Mini, Downlight (Mini D and similar) | 3.90 | works (confirmed on Mini D) |
| A19 between those generations | 2.80 to 2.90 | untested, likely fine |
| Matter/Thread models | n/a | unknown, may not support it |

Bulbs speak TLS 1.0, which OpenSSL 3.x refuses by default. The provisioner lowers the TLS floor and security level on its own connection only. Do not edit `/etc/ssl/openssl.cnf` to work around this, which would weaken TLS for the whole host.

## License

The repository is MIT. See [LICENSE](LICENSE). The one exception is `src/lifx_set_ssid.py`, which is derived from `onboard.py` in [tserong/lifx-hacks](https://github.com/tserong/lifx-hacks) by Tim Serong and is therefore under the GNU AGPL-3.0. See [src/LICENSE-AGPL-3.0](src/LICENSE-AGPL-3.0). The shell script runs it as a separate process and does not link against it.
