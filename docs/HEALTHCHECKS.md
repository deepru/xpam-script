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

Deep health performs broader checks and is recommended after installation, updates, repair, DoubleHop changes and network troubleshooting.

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
