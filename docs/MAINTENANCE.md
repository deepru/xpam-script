# Weekly maintenance

XPAM Script creates automatic weekly maintenance.

The maintenance command exists internally as:

```text
/usr/local/sbin/<prefix>-weekly-maintenance.sh
```

It is not a normal user-facing command and is not shown as a routine user command.

---

## What weekly maintenance does

The weekly job performs:

- safe temporary cleanup;
- XPAM log and backup retention;
- old generic backup cleanup;
- apt/dpkg recovery checks;
- `apt update`;
- full-upgrade simulation;
- guarded full-upgrade;
- autoremove simulation;
- guarded autoremove purge;
- certificate renewal;
- service reload/restart;
- DNS policy check;
- service hygiene apply/check;
- health check;
- kernel/reboot check;
- network tuning check;
- final failed systemd units check.

---

## Notifications

Telegram notifications are optional.

The weekly job is intentionally quiet. It sends notification only when:

- maintenance fails;
- health check fails;
- manual reboot is needed.

It is not intended to spam successful weekly reports.
