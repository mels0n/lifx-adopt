# ADR-0003: Per-bulb cooldown, hard timeout, guaranteed radio restore

Status: accepted (2026-09-30)

## Context

The tool runs unattended on a timer and switches a radio on and off. Two failure modes matter: a bulb that can never be adopted (dead radio, a model that ignores `SetAccessPoint`) would make the host cycle its radio every pass forever, and a radio left associated to a bulb's setup network after a crash or kill is worse than any single failed adoption.

## Decision

- Count consecutive failures per bulb, keyed by the BSSID from the scan, in a root-only state file. Three failures suppress that bulb for 24 hours; a success clears its counter.
- Restore the radio on every exit path: a shell `trap` on `EXIT`, `INT` and `TERM`, plus `ExecStopPost=` on the unit, which runs even if the script itself was killed.
- Put a `TimeoutStartSec` on the unit, and bound every `iw scan` call with `timeout -k`. `iw scan` can block indefinitely on some drivers and hold the lock through inherited file descriptors after its parent dies, so the scan is split into an asynchronous trigger and a read of the cached table.
- Run the timer with `OnUnitInactiveSec`, not `OnUnitActiveSec`, so the interval is measured from the end of a pass.
- No notification channel. `journalctl -u lifx-adopt` is the record.

## Alternatives considered

- **Cooldown keyed by the SSID suffix.** The BSSID is what the scan reports authoritatively; parsing the name is fragile and setup SSIDs contain spaces.
- **Notifications by email or webhook.** Would put a credential or endpoint on every host running this. A journal line is enough for a tool that acts only after you deliberately reset a bulb.
- **Cross-host locking when two hosts cover the same area.** Needs shared state and adds a failure mode to prevent a race that is harmless: whichever host adopts a bulb first removes its setup network, and the other finds nothing.

## Consequences

An unadoptable bulb costs three attempts a day at most. The cooldown counter is not reset when the window expires, so the first failure after a suppression ends re-suppresses the bulb immediately. Clear the state file after fixing whatever was wrong.
