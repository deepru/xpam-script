# Configuration

XPAM Script stores runtime configuration under `/etc/xpam-script/` and installs the runtime kit under `/opt/xpam-script/`.

Most users should manage XPAM through the prefix command:

```bash
sudo <prefix>-xpam
```

## Main commands

```bash
sudo <prefix>-xpam                 # main XPAM menu
sudo <prefix>-links                # safe connection summary
sudo <prefix>-links --show-secrets # full connection data
sudo <prefix>-health               # quick health check
sudo <prefix>-health --deep        # extended health check
sudo <prefix>-repair               # repair XPAM runtime glue
sudo <prefix>-netdiag              # network diagnostics
```

## Domains

Use separate DNS names for the roles you configure during installation. Examples:

```text
vless.example.com
tg.example.com
panel.example.com
```

Do not publish live domains in public issues unless they are intentionally public.

## Links

XPAM centralizes user connection data in:

```bash
sudo <prefix>-links --show-secrets
```

The full output shows current VLESS and Telegram links from the active 3x-ui configuration. After adding/removing VLESS clients or rotating the Telegram proxy / MTG secret in 3x-ui, run the command again and use the updated links.

The safe summary is:

```bash
sudo <prefix>-links
```

## DoubleHop Mode

DoubleHop Mode is configured from the main XPAM menu. The Exit VLESS link should be treated as a secret.

XPAM only configures the Entry server. It does not create, repair or remove clients on the Exit server.

## Manual edits

Avoid manual edits to generated nginx, HAProxy, 3x-ui, systemd or XPAM files unless you know how to restore the server.

After changes, run:

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
```
