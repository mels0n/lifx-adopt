# ADR-0002: Join with `iw connect` and a static address

Status: accepted (2026-09-30)

## Context

The tool has to join a bulb's setup network from a host that may already run `wpa_supplicant` for other purposes or manage its interfaces with a network manager, and different distributions ship different DHCP clients.

## Decision

Setup networks are always open, so join with `iw dev <iface> connect` directly: no supplicant, no configuration file, no process to manage. The bulb is always at `172.16.0.1`, so assign `172.16.0.2/24` to the interface statically instead of running a DHCP client. Poll TCP port 56700 before provisioning, because association succeeding does not mean the bulb is reachable yet.

## Alternatives considered

- **`wpa_supplicant` bound to the interface.** Unnecessary for an open network, and it collides with a system-wide supplicant daemon that is already running on many hosts.
- **A DHCP client.** Adds a dependency that differs between distributions, costs several seconds per bulb, and adds a failure mode, all to learn an address that never changes. If a future bulb model uses a different subnet, DHCP is the remedy.
- **Waiting a fixed time after association.** Racy. Polling the port the tool actually needs is exact.

## Consequences

The tool requires an interface nothing else manages, since it takes the interface up and down and flushes its addresses. The trade is that the join path is a handful of `iw` and `ip` calls with no state left behind.
