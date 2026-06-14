# Security Policy

## Supported version

Only the current XPAM Script v1.3.5 documentation and release path are maintained.

Use the latest published release from GitHub Releases for new installations.

## Secrets

Do not publish or paste publicly:

- VLESS links;
- Telegram links;
- Exit VLESS link used for DoubleHop Mode;
- UUIDs;
- Telegram bot tokens;
- relay tokens;
- WARP/WireGuard credentials;
- private keys;
- certificate private keys;
- `/etc/xpam-script/config.env`;
- output from `sudo <prefix>-links --show-secrets`.

The safe command for public diagnostics is:

```bash
sudo <prefix>-links
```

The following command prints sensitive connection data and must be treated as secret:

```bash
sudo <prefix>-links --show-secrets
```

## DoubleHop Mode

The Exit VLESS link used for DoubleHop Mode is a secret. Protect it like any other proxy credential.

XPAM configures DoubleHop Mode on the Entry server only. It does not automatically manage the Exit server.

## Update safety

XPAM safe self-update must verify the downloaded archive, run preflight checks, create a backup, run post-update health checks and roll back on failure.

Update logs must not contain live connection links, tokens or private keys.

## Logs

Before sharing logs, redact:

- domains;
- IP addresses;
- UUIDs;
- URLs containing credentials;
- tokens;
- private keys;
- local backup paths that reveal private environment details.

## Reporting a vulnerability

Open a private security report if available, or create a public issue with all secrets redacted. Do not include live connection links or credentials.

## Operational notes

- Install XPAM Script on a clean VPS.
- Keep SSH keys secure.
- Use `sudo <prefix>-health --deep` after significant changes.
- Use XPAM safe self-update instead of manual overwrites.
- Do not manually edit generated service files unless you know how to restore the server.
