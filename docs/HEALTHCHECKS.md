# Health checks

XPAM Script provides quick and extended health checks.

## Quick health

```bash
sudo <prefix>-health
```

This checks the main runtime state and service availability.

## Deep health

```bash
sudo <prefix>-health --deep
```

Deep health performs broader checks and is recommended after installation, updates, repair, DoubleHop or WARP changes, enabling the spare transport, and network troubleshooting.

Among other things it verifies that the masking sites still answer normally, that the panel stays protected, that WARP (when configured) keeps the expected IPv4-only shape, and — when the spare transport is enabled — that its inbound listens and that its secret path actually reaches Xray instead of falling through to the decoy.

## What is covered

Health checks cover the XPAM-managed stack, including:

- command surface;
- nginx / HAProxy state;
- 3x-ui / Xray state;
- VLESS availability;
- Telegram proxy / MTG state;
- certificate and routing assumptions;
- DoubleHop consistency when enabled;
- small-VM policies and maintenance assumptions.

## After changes

Run both checks after significant operations:

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
```

If a check fails, use `sudo <prefix>-repair` or inspect logs with secrets redacted before sharing.
