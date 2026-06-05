# Maintenance

XPAM Script installs a weekly maintenance flow and profile-prefixed helper commands.

The normal operator entry points are:

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
sudo <prefix>-repair
sudo <prefix>-netdiag
```

Weekly maintenance is configured automatically and is not the primary interactive user workflow.

---

## Weekly maintenance

Weekly maintenance performs guarded package operations, certificate renewal checks, config snapshots, retention cleanup and a post-maintenance quick health check.

It is designed to keep the server tidy without changing user secrets, VLESS UUIDs, MTProto secrets or selected domains.

---

## Repair

Repair restores the XPAM runtime and service policy around the installed server.

It can refresh:

- `/opt/xpam-script` runtime files;
- profile-prefixed launchers;
- health/deep-health helpers;
- weekly maintenance helpers;
- service limits;
- startup ordering;
- fail2ban policy;
- certbot hook;
- selected service hygiene settings.

Repair does not replace the user’s domains, VLESS UUID, MTProto secret or Telegram secrets.

---

## Final production cleanup

Final production cleanup is available from the menu:

```text
7) Дополнительно
4) Финальная production-очистка
```

If the operator skipped final production cleanup during installation or wants to run it again, the same menu item can be used later.

The cleanup keeps the files required to manage the server, including runtime files, secure notes, config backups, manual backups, systemd services and working site/configuration files.
