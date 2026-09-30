# AGENTS.md

Contributor guide for this repository.

## What it is

A how-to and small tool for re-onboarding factory-reset LIFX bulbs from a Linux host with an idle WiFi radio. A bash loop finds LIFX setup networks, joins one, and a Python script sends the bulb your WiFi credentials.

## Layout

- `bin/`: the loop script
- `src/`: the Python provisioner (AGPL-3.0, derived from tserong/lifx-hacks; license text alongside)
- `systemd/`: service and timer units
- `tests/`: unit tests for packet building and reply parsing
- `docs/adr/`: architecture decision records

## Checks

- `python -m py_compile src/lifx_set_ssid.py tests/test_lifx_set_ssid.py`
- `python -m unittest discover -s tests`
- `bash -n bin/lifx-adopt.sh`
- `shellcheck bin/lifx-adopt.sh`, if you have it
- Never run the adopter on a machine whose WiFi radio carries its own connection. It brings the interface up and down and flushes its addresses.

## Conventions

- Keep examples generic: no real SSIDs, passphrases, bulb MAC addresses, hostnames, or private addresses. The only addresses that belong here are LIFX's own setup-network pair, `172.16.0.1` (bulb) and `172.16.0.2` (host).
- Credentials come from the root-only environment file, never from the script and never from argv.
- The radio must be restored on every exit path. Anything that adds a new way to exit needs to keep that true.
- Success is decided by the bulb's `StateAccessPoint` reply, not by the setup network disappearing.
- Bulb SSIDs contain spaces, so scan output stays tab-delimited.
- Explain non-obvious steps with a comment next to the step.
