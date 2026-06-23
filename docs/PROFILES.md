# Runtime modes

XPAM Script v1.3.6 uses a simplified public model. Installation prepares the server with the current VLESS and Telegram proxy / MTG architecture, and optional features are managed later from the XPAM menu.

## Standard installed state

A normal v1.3.6 installation provides:

- VLESS through 3x-ui/Xray;
- Telegram proxy / MTG through 3x-ui;
- nginx masking/fallback sites;
- HAProxy public HTTPS/TLS routing;
- Certbot TLS automation;
- firewall and basic SSH protection;
- health/deep-health;
- repair and weekly maintenance;
- safe self-update.

## Optional runtime features

Optional features are enabled from:

```bash
sudo <prefix>-xpam
```

Important runtime features:

- WARP through 3x-ui/Xray;
- DoubleHop Mode;
- site management;
- safe self-update.

## DoubleHop Mode

DoubleHop Mode is a runtime mode, not a separate installation profile.

Supported modes:

- VLESS only;
- Telegram only;
- VLESS + Telegram.

XPAM configures only the Entry server. The Exit server is prepared separately by the user and is represented in XPAM by an Exit VLESS link.

Existing Entry-side VLESS and Telegram links must remain unchanged when DoubleHop is enabled, changed or disabled.
