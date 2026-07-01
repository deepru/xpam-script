# Maintenance

XPAM Script installs maintenance helpers for repair, diagnostics, weekly checks and safe updates.

## Repair

```bash
sudo <prefix>-repair
```

Repair restores XPAM runtime glue and generated helper commands. It should not change VLESS or Telegram links.

VLESS and Telegram links shown by `sudo <prefix>-links --show-secrets` are expected to come from the current 3x-ui configuration, not from stale text copies.

## Weekly maintenance

Weekly maintenance is configured automatically. It keeps the XPAM-managed server state consistent and should not recreate removed legacy command surfaces or change user connection links. It must not revert a valid Telegram proxy / MTG secret that was changed in 3x-ui.

## Network diagnostics

```bash
sudo <prefix>-netdiag
```

Use network diagnostics when DNS, TLS, routing or connectivity checks fail.

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
