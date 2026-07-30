# Maintainer notes

This file describes public maintainer rules for XPAM Script.

## Public architecture

XPAM Script is documented as a VPS automation project for:

- VLESS through 3x-ui/Xray;
- Telegram proxy / MTG through 3x-ui;
- nginx + HAProxy + TLS routing;
- DoubleHop Mode;
- WARP through 3x-ui/Xray;
- an optional spare VLESS transport (xhttp/grpc) on a separate domain;
- health/deep-health;
- repair and weekly maintenance;
- safe self-update.

Use the current public terminology consistently: **Telegram proxy / MTG**, **Telegram link**, **DoubleHop Mode**, `sudo <prefix>-xpam`, `sudo <prefix>-links`.

## Command surface invariants

- `sudo <prefix>-xpam` is the primary management interface.
- `sudo <prefix>-links` is the safe connection summary.
- `sudo <prefix>-links` prints sensitive connection data.
- VLESS and Telegram links shown by `sudo <prefix>-links` must be generated from the current 3x-ui configuration.
- Public documentation should not reference removed user-facing command names from older releases.

## DoubleHop invariants

- XPAM manages DoubleHop on the Entry server only.
- The Exit server is prepared separately by the user.
- XPAM uses a user-provided Exit VLESS link.
- Enabling, changing or disabling DoubleHop must not change existing Entry-side VLESS or Telegram links.
- Manual Telegram proxy / MTG secret rotation in 3x-ui must be reflected by `sudo <prefix>-links` and must not be reverted by health, repair or weekly maintenance.
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

State supported platforms as **Ubuntu and Debian**, with no version numbers. That matches what the code actually enforces: `require_os` accepts a distribution by `ID` only and applies no version floor or ceiling, and health checks deliberately avoid pinning to a `VERSION_ID` so newer releases cannot false-FAIL. Naming specific releases would therefore understate real compatibility, and it decays — a pair of version numbers that reads as "current" today reads as "abandoned" once the next releases ship, while the code keeps working. Supported platforms are a **product property**: state them once (README, `docs/`, `TESTING.md`), not per release.

Do not expose internal stage names, validation stage matrices, or "what we tested against" as the public testing story — that includes third-party component versions such as the 3x-ui or Xray build a release happened to be developed on. The user's concern is whether the product works on their server, not our test log. Kit provenance belongs in `BUILD_INFO`, the changelog and git history.

Dated version numbers are fine in two places: historical changelog entries (a past release legitimately describes what it was verified against) and examples inside an error message aimed at someone who has already hit the problem.
