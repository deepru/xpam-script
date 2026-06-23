# Architecture

XPAM Script v1.3.6 prepares a clean VPS as a managed HTTPS/TLS stack with VLESS, Telegram proxy / MTG, 3x-ui/Xray, nginx, HAProxy, health checks, maintenance and safe self-update.

## High-level model

```text
Internet :443
  -> HAProxy
      -> 3x-ui / Xray VLESS
      -> Telegram proxy / MTG through 3x-ui
      -> nginx masking/fallback sites
      -> optional WARP outbound through Xray
      -> optional DoubleHop outbound through Exit VLESS link
```

## Components

- **3x-ui/Xray** — VLESS, routing and outbound management.
- **Telegram proxy / MTG through 3x-ui** — Telegram connectivity through the 3x-ui stack.
- **HAProxy** — public HTTPS/TLS routing layer.
- **nginx** — local masking/fallback sites.
- **Certbot / Let's Encrypt** — TLS certificates.
- **UFW / fail2ban** — firewall and basic SSH protection.
- **XPAM runtime scripts** — links, health, repair, maintenance, update and diagnostics.

## Command surface

XPAM creates prefix-based commands:

```bash
sudo <prefix>-xpam
sudo <prefix>-links
sudo <prefix>-health
sudo <prefix>-repair
sudo <prefix>-netdiag
```

`sudo <prefix>-xpam` is the main management interface.

## Link model

Connection links are managed centrally:

```bash
sudo <prefix>-links
sudo <prefix>-links --show-secrets
```

The first command is safe for diagnostics and does not print secrets. The second command prints full connection data and must be treated as sensitive.

For VLESS and Telegram proxy / MTG, the full links output is built from the current 3x-ui configuration. If a VLESS client or Telegram proxy / MTG secret is changed in 3x-ui, run the command again and use the updated links.

## DoubleHop Mode

DoubleHop Mode is an Entry-side runtime mode.

The Entry server accepts existing VLESS and Telegram links. Selected traffic may then exit through another server using a user-provided Exit VLESS link.

XPAM does not automatically manage the Exit server. The Exit server is prepared separately by the user.

Supported DoubleHop modes:

- VLESS only;
- Telegram only;
- VLESS + Telegram.

Entry-side VLESS and Telegram links must remain unchanged when DoubleHop is enabled, changed or disabled.

## Safe self-update model

XPAM v1.3.6 includes manual safe self-update:

```text
release metadata -> archive + sha256 download -> SHA256 verification -> staging extract -> preflight -> backup -> apply -> postcheck -> rollback if needed
```

The updater must not print secrets in logs.
