# Maintainer notes

This file describes public maintainer rules for XPAM Script.

## Public architecture

XPAM Script is documented as a VPS automation project for:

- VLESS through 3x-ui/Xray;
- Telegram proxy / MTG through 3x-ui;
- nginx + HAProxy + TLS routing;
- DoubleHop Mode;
- WARP through 3x-ui/Xray;
- health/deep-health;
- repair and weekly maintenance;
- safe self-update.

Use the current public terminology consistently: **Telegram proxy / MTG**, **Telegram link**, **DoubleHop Mode**, `sudo <prefix>-xpam`, `sudo <prefix>-links`.

## Command surface invariants

- `sudo <prefix>-xpam` is the primary management interface.
- `sudo <prefix>-links` is the safe connection summary.
- `sudo <prefix>-links --show-secrets` prints sensitive connection data.
- VLESS and Telegram links shown by `sudo <prefix>-links --show-secrets` must be generated from the current 3x-ui configuration.
- Public documentation should not reference removed user-facing command names from older releases.

## DoubleHop invariants

- XPAM manages DoubleHop on the Entry server only.
- The Exit server is prepared separately by the user.
- XPAM uses a user-provided Exit VLESS link.
- Enabling, changing or disabling DoubleHop must not change existing Entry-side VLESS or Telegram links.
- Manual Telegram proxy / MTG secret rotation in 3x-ui must be reflected by `sudo <prefix>-links --show-secrets` and must not be reverted by health, repair or weekly maintenance.
- Public documentation must not imply automatic Exit-server management.

## Update invariants

Safe self-update must follow this model:

```text
release metadata -> archive + sha256 -> SHA256 verification -> staging extract -> preflight -> backup -> apply -> postcheck -> rollback if needed
```

The updater must not print live connection links, tokens or private keys in logs.

## Documentation safety

Public files must not contain real project/operator data, including:

- real domains;
- real IP addresses;
- real VLESS links;
- real Telegram links;
- UUIDs or tokens;
- mock URLs;
- local operator paths;
- internal validation logs.

Use neutral placeholders such as:

```text
example.com
vless.example.com
tg.example.com
<server-ip>
<prefix>
<exit-vless-link>
<redacted>
```

## Release documentation

For public testing wording, state that the release was tested on Ubuntu and Debian, including Debian 13 and Ubuntu 26.04. Do not expose internal stage names or validation stage matrices as the public testing story.
