# Security model

XPAM Script automates a security-sensitive VPS stack. Treat generated connection data and configuration files as private.

## Secret data

Sensitive data includes:

- VLESS links;
- Telegram links;
- Exit VLESS link for DoubleHop Mode;
- UUIDs;
- tokens;
- private keys;
- WARP/WireGuard credentials;
- `/etc/xpam-script/config.env`;
- output from `sudo <prefix>-links --show-secrets`.

## Safe and unsafe link commands

Safe diagnostic summary:

```bash
sudo <prefix>-links
```

Sensitive full output:

```bash
sudo <prefix>-links --show-secrets
```

Never paste the full output into a public issue.

The full output may include current VLESS and Telegram links generated from the active 3x-ui configuration.

## DoubleHop Mode

The Exit VLESS link is a credential. Anyone with it may be able to use the Exit-side access it represents.

XPAM configures DoubleHop on the Entry server only. It does not manage the Exit server.

## Update logs

Safe self-update must not print live connection links, tokens or private keys in logs.

Before sharing update logs, redact domains, IP addresses, URLs, UUIDs, tokens and local paths.
