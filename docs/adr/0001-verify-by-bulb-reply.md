# ADR-0001: Decide success from the bulb's StateAccessPoint reply

Status: accepted (2026-09-30)

## Context

The first version of this tool verified an adoption by absence: after sending the credentials it rescanned, and treated the setup network vanishing as proof the bulb had left. On the first real run that reported a successful adoption as a failure. `iw scan dump` reads a cached BSS table that keeps listing an access point for tens of seconds after it stops beaconing, and the bulb needs time to reboot and join your network regardless.

## Decision

A bulb that accepts `SetAccessPoint` answers with a `StateAccessPoint` frame (message type 308) whose payload echoes the SSID it stored. The provisioner exits 0 only when the type is 308, the echoed SSID matches the one sent, and the interface byte reads station. The setup network still being visible afterwards is logged as an advisory note and never overrides the reply.

## Alternatives considered

- **Rescan and expect the setup network to be gone.** Wrong for the cache reason above, and it would need a long fixed delay to be even approximately right.
- **Ask your router or Home Assistant whether the bulb appeared.** Correct but slow, and it adds a dependency on a second system and its credentials. The bulb's own reply is direct, local, and immediate.

## Consequences

Verification needs no credentials beyond the WiFi passphrase and no network access beyond the setup link. The tool cannot tell whether the bulb then successfully joined your network (wrong passphrase, weak signal), only that it accepted and stored the credentials.
