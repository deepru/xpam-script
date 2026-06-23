# Troubleshooting

This guide lists common XPAM Script v1.3.6 troubleshooting steps.

## Main command not found

Check the prefix you selected during setup. The main command is:

```bash
sudo <prefix>-xpam
```

If the command is missing, run repair from the installed runtime if available, or re-run the current release installer according to the release instructions.

## Links command does not show full data

The safe command does not print secrets:

```bash
sudo <prefix>-links
```

Use the full command only in a private terminal:

```bash
sudo <prefix>-links --show-secrets
```

Do not paste this output into public reports.

If you manually changed a VLESS client or Telegram proxy / MTG secret in 3x-ui, run the full command again and use the current links from its output.

## Health failed

Run:

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
```

Then try:

```bash
sudo <prefix>-repair
sudo <prefix>-health --deep
```

If you report the issue, redact domains, IP addresses, links, UUIDs, tokens and local paths.

## DoubleHop does not enable

Check that:

- the Exit VLESS link is valid;
- the Exit server is reachable;
- the Entry server passes health/deep-health before enabling DoubleHop;
- you selected the intended DoubleHop mode.

XPAM does not configure the Exit server automatically.

## DoubleHop enabled but connection still looks direct

Confirm the selected mode. VLESS only, Telegram only and VLESS + Telegram affect different traffic types.

Run:

```bash
sudo <prefix>-xpam
```

Then open `DoubleHop Mode` → `Показать статус`.

## Update failed

Safe self-update should either complete successfully or roll back to the previous working version.

After a failed update, run:

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
```

Do not publish update logs without redacting secrets and environment details.

## Low disk or low memory warnings

v1.3.6 includes small-VPS safeguards, but very small VPS plans can still fail during package installation, certificate issuance or updates.

Free disk space and make sure the package manager is not in a broken state before retrying.

## Telegram notifications do not work

Telegram notifications are separate from Telegram proxy / MTG. Check bot token, relay settings and network access.


## GitHub CDN timeout during bootstrap/update

Some VPS networks can reach `github.com` but time out against one GitHub CDN edge used by `raw.githubusercontent.com` or `release-assets.githubusercontent.com`. The symptom is usually `curl: (28) SSL connection timeout`.

XPAM download paths use HTTP/1.1 retries/timeouts and mandatory SHA256 verification. If GitHub is temporarily unreachable from the provider network, retry later or download the release archive from another network and upload it manually.

For the very first bootstrap file, before XPAM is running, use the fallback command from `README.md` / `docs/INSTALLATION.md` if the normal `curl` command times out.
