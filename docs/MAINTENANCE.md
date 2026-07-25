# Maintenance

XPAM Script installs maintenance helpers for repair, diagnostics, weekly checks and safe updates.

## Repair

```bash
sudo <prefix>-repair
```

Repair restores XPAM runtime glue and generated helper commands, and re-asserts the front layer (nginx, HAProxy, the spare transport front when enabled) and the WARP outbound shape. It does not change VLESS or Telegram links.

VLESS and Telegram links shown by `sudo <prefix>-links` are expected to come from the current 3x-ui configuration, not from stale text copies.

## Weekly maintenance

Weekly maintenance is configured automatically and runs on a schedule once a week. It takes a configuration snapshot, applies system updates, renews certificates, runs a health check and prunes old logs and backups within the configured limits.

It does not change user connection links, does not revert a Telegram proxy / MTG secret changed in 3x-ui, and does not reboot the server on its own — if a reboot is needed to finish an update, it says so (and notifies over Telegram when notifications are configured). To run it by hand:

```bash
sudo <prefix>-weekly-maintenance.sh
```

## Network diagnostics

Network diagnostics no longer has its own command — it is run from the menu:

```bash
sudo <prefix>-xpam
```

Open `Дополнительно / обслуживание` → `Диагностика сети Debian/провайдера`.

Use it when DNS, TLS, routing or connectivity checks fail.

## Safe self-update

Safe self-update is available from:

```bash
sudo <prefix>-xpam
```

Open `Дополнительно` → `Проверить обновления XPAM`.

The updater must:

- verify SHA256 before applying an update;
- run staging preflight;
- create a backup;
- run post-update health/deep-health;
- roll back if the updated state is not healthy;
- preserve VLESS and Telegram links;
- preserve current 3x-ui-sourced VLESS/Telegram link behavior.

## Small-VPS policy

XPAM includes small-VM safeguards such as journald/logrotate policies, resource checks and backup retention.
