# Health checks

The health command is:

```bash
sudo <prefix>-health
```

It validates the server from the operator’s point of view.

The normal health output is intentionally compact. Full diagnostics are available through:

```bash
sudo <prefix>-health --deep
```

---

## Main checks

The health script checks:

- failed systemd units;
- nginx service and config;
- x-ui service;
- fail2ban;
- certbot timer;
- UFW/firewall policy;
- cron;
- SSH config syntax;
- SSH service/socket;
- HAProxy and MTProto, when used;
- HAProxy/MTProto startup ordering;
- public HTTP/HTTPS routes;
- Basic Auth panel path response;
- MTProto secret leakage in recent journal;
- 3x-ui database settings and schema compatibility;
- Xray generated config;
- 3x-ui API token storage and Bearer access;
- TLS certificate consistency;
- public and loopback port exposure;
- optional WARP state;
- Telegram Relay, when configured;
- service hygiene;
- config snapshot freshness;
- disk and inode usage;
- swap policy;
- kernel/reboot requirement;
- DNS/provider behavior;
- network tuning;
- service file descriptor limits.

---

## Result

A healthy server ends with:

```text
OK: <PREFIX> server looks healthy
```

A failed or suspicious check is reported as `FAIL` or warning text. Do not ignore failed systemd units.
