# Troubleshooting

Common problems and what to do about them.

Before pasting any output into an issue, a chat or a screenshot, check what has to be removed first:
[`SECURITY.md`](../SECURITY.md).

## Main command not found

Check the prefix you selected during setup. The main command is:

```bash
sudo <prefix>-xpam
```

If the command is missing, run repair from the installed runtime if available, or re-run the current release installer according to the release instructions.

## Links command does not show full data

`sudo <prefix>-links` already prints everything — links, panel address and credentials. There is no extra flag to reveal secrets.

```bash
sudo <prefix>-links
```

Do not paste that output into public reports; use `sudo <prefix>-links --safe` for a summary without secrets.

If you manually changed a VLESS client or Telegram proxy / MTG secret in 3x-ui, run the command again and use the current links from its output.

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

`sudo <prefix>-links --safe` gives a summary you can share without stripping anything.

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

## WARP looks configured but is not used

If DoubleHop is enabled for VLESS, all VLESS traffic goes to the Exit server, so the WARP rules never
match. This is expected: the WARP configuration is kept and takes effect again once DoubleHop is
switched off. In `Telegram only` mode VLESS stays direct and WARP keeps working.

## Clients cannot connect while the server itself is healthy

If `sudo <prefix>-health --deep` passes and the domains open in a browser, but a client cannot
connect — or connects only sometimes, typically on one network — the problem is usually the path to
the server rather than the server.

- Test the same link from a different network (for example a phone hotspot).
- Re-copy the link: `sudo <prefix>-links`.
- Enable the optional **spare VLESS transport** on a separate domain
  (`sudo <prefix>-xpam` → `Дополнительно` → `Транспорты VLESS`) and add its link to the client as a
  second server. The primary transport is untouched and keeps working.
- If `xhttp` performs poorly, switch to `grpc` (or the other way round): which one survives depends
  on the network, and switching reuses the same domain and certificate.

## Update failed

Safe self-update should either complete successfully or roll back to the previous working version.

After a failed update, run:

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
```

Update logs are written without connection links or tokens, but still mention your domains — strip
those before sharing.

## Low disk or low memory warnings

XPAM includes small-VPS safeguards, but very small VPS plans can still fail during package installation, certificate issuance or updates.

Free disk space and make sure the package manager is not in a broken state before retrying.

## Telegram notifications do not work

Telegram notifications are separate from Telegram proxy / MTG. Check bot token, relay settings and network access.


## GitHub CDN timeout during bootstrap/update

Some VPS networks can reach `github.com` but time out against one GitHub CDN edge used by `raw.githubusercontent.com` or `release-assets.githubusercontent.com`. The symptom is usually `curl: (28) SSL connection timeout`.

XPAM download paths use HTTP/1.1 retries/timeouts and mandatory SHA256 verification. If GitHub is temporarily unreachable from the provider network, retry later or download the release archive from another network and upload it manually.

For the very first bootstrap file, before XPAM is running, use the fallback command from `README.md` / `docs/INSTALLATION.md` if the normal `curl` command times out.
