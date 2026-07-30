# Security model

What XPAM exposes, what it keeps closed, and where the trust boundaries are.

The list of things that count as secrets — and what to strip before posting a log, a screenshot or an
issue — is kept once, in [`SECURITY.md`](../SECURITY.md).

## What is reachable from the internet

Only three TCP ports are open: `22` for SSH, `80` for certificate issuance and renewal, and `443` for
everything else. There is no separate port for VLESS or for the Telegram proxy.

HAProxy accepts `443` and routes by the requested domain name. A request that does not match a
configured domain — or that is not a proxy connection at all — reaches an ordinary masking website.
That is deliberate: a prober gets a normal-looking site, not an error and not a bare endpoint.

## What is not reachable from the internet

The 3x-ui panel and the backends behind nginx listen on loopback only. The panel is additionally
placed under a secret path, protected by Basic Auth at the nginx level, and has its own 3x-ui login on
top of that. The 3x-ui subscription service is switched off outright, so it publishes nothing.

## Where the trust boundaries are

- **The server operator has root.** `<prefix>-links` prints connection data in full because anyone
  able to run it already has the access that data grants. The protection is against onlookers and
  against pasting it somewhere public, not against the operator.
- **Connection links are credentials.** Anyone holding a VLESS or Telegram link can use the server.
  Removing a client in 3x-ui is what revokes it.
- **The Exit server in DoubleHop Mode is outside XPAM.** XPAM only holds its VLESS link and routes
  traffic to it; it never logs in there and never manages it. That link is a credential for someone
  else's server.
- **3x-ui is a moving component.** XPAM configures it and checks its state, but the panel remains a
  general-purpose tool: changes made there directly can conflict with what XPAM maintains.

## Updates

Safe self-update downloads a published release, verifies its checksum, backs up the current version,
applies the new one, re-checks the server and rolls back if the result is not healthy. Connection
links are compared before and after, so an update cannot silently change a link users already hold.
Update logs are written without connection links, tokens or private keys.
