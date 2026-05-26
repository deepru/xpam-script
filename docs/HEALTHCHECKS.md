# Health checks

The health command is:

```bash
sudo <prefix>-health
```

It validates the server from the operator’s point of view.

---

## Main checks

The health script checks:

- failed systemd units;
- nginx service and config;
- x-ui service;
- fail2ban;
- certbot timer;
- UFW;
- cron;
- SSH config syntax;
- SSH service/socket;
- HAProxy and MTProto, when used;
- HTTP routes;
- Basic Auth panel path response;
- MTProto secret leakage in recent journal;
- systemd startup ordering;
- 3x-ui database settings;
- Xray generated config;
- TLS certificate consistency;
- public and loopback port exposure;
- service hygiene;
- config snapshot freshness;
- disk and inode usage;
- swap policy;
- kernel/reboot requirement;
- DNS policy;
- network tuning;
- Telegram Relay, when configured.

---

## Result

A healthy server ends with:

```text
OK: <PREFIX> server looks healthy
```

A failed or suspicious check is reported as `FAIL` or warning text. Do not ignore failed systemd units.
