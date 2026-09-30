# ADR-0004: Lower the TLS floor on one connection only

Status: accepted (2026-09-30)

## Context

LIFX bulbs speak TLS 1.0 on port 56700. OpenSSL 3.x refuses TLS 1.0 and the old cipher suites by default, so the provisioning connection fails on a current Linux host. Upstream advises setting `MinProtocol = TLSv1.0` in `/etc/ssl/openssl.cnf`.

## Decision

The provisioner builds its own `ssl.SSLContext` with `minimum_version = TLSv1`, the `DEFAULT@SECLEVEL=0` cipher string, and `OP_LEGACY_SERVER_CONNECT`. Certificate verification is disabled for that context, since the bulb's certificate is self-signed. Nothing about host TLS policy changes.

## Alternatives considered

- **Edit `openssl.cnf`.** Works, and weakens TLS for every program on the host.
- **Shell out to a separate TLS client.** More moving parts for no gain over a scoped context.

## Consequences

The weakened settings live in one function and apply to one short-lived connection to a device on a private setup link. The passphrase is exposed to anyone able to impersonate the open setup network, which the README states plainly.
