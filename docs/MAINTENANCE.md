# Maintenance

XPAM Script installs maintenance helpers for repair, diagnostics, weekly checks and safe updates.

## Repair

```bash
sudo <prefix>-repair
```

Repair restores XPAM runtime glue and generated helper commands, and re-asserts the front layer (nginx, HAProxy, the spare transport front when enabled) and the WARP outbound shape. It does not change VLESS or Telegram links.

VLESS and Telegram links shown by `sudo <prefix>-links` are expected to come from the current 3x-ui configuration, not from stale text copies.

## Weekly maintenance

Weekly maintenance is configured automatically and runs on a schedule once a week, at night. It takes a configuration snapshot, applies system updates, renews certificates, runs a health check and prunes old logs and backups within the configured limits.

It does not change user connection links and does not revert a Telegram proxy / MTG secret changed in 3x-ui.

**It does reboot the server when an update requires it.** In the default `auto` mode weekly installs every available update including kernels, and reboots if the box needs one to finish. After that reboot a one-shot pass runs automatically: it waits for the services to come up, applies whatever became available after the first batch, cleans up and verifies health, then disables itself. Telegram notifications (when configured) are sent on failure only.

To keep the server from rebooting on its own, set `XPAM_MAINT_APT_MODE=upgrade` in `/etc/xpam-script/config.env` (plain package upgrade, kernels held back) or `off` (no system updates at all). The value is read on every run, so saving the file is enough. Do not use the legacy value `security`: it behaves like `upgrade`, but XPAM migrates that exact value back to `auto`.

To run weekly maintenance by hand:

```bash
sudo <prefix>-weekly-maintenance.sh
```

## Network diagnostics

```bash
sudo <prefix>-netdiag
```

The same action is available from the menu: `sudo <prefix>-xpam` →
`Дополнительно / обслуживание` → `Диагностика сети Debian/провайдера`.

This does not diagnose anything by itself and prints no verdict: it collects a snapshot of the
server's network state — OS, failed units, `networking.service` and its journal, interfaces,
addresses, routes, `/etc/network/interfaces`, resolver state and the XPAM DNS-policy check — into
`/var/log/xpam-script/netdiag/<prefix>-<timestamp>/netdiag.txt`, mode `600`, and prints the path. Read
that file.

Use it when the server misbehaves specifically on the network, or when you need to hand someone the
whole picture at once. The file contains the server and gateway IPs, DNS addresses and your domains —
review it before sharing. For a plain "is the server healthy" verdict use `sudo <prefix>-health --deep`.

## Safe self-update

Safe self-update is available from:

```bash
sudo <prefix>-xpam
```

Open `Дополнительно` → `Проверить обновления XPAM`.

The updater verifies the release checksum, runs preflight checks on the staged copy, backs up the current version, applies the update and re-checks the server. If the result is not healthy it rolls back to the previous version. Connection links are captured before and after and must match, so an update never silently changes a link your clients already hold.

## Small-VPS policy

XPAM includes small-VM safeguards such as journald/logrotate policies, resource checks and backup retention.
