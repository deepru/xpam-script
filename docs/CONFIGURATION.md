# Configuration model

The main persistent configuration file is:

```text
/etc/xpam-script/config.env
```

It is created during installation and loaded by runtime launchers.

---

## Important variables

| Variable | Meaning |
|---|---|
| `SERVER_PREFIX` | command prefix chosen during step `0` |
| `PROFILE` | selected deployment profile |
| `ROOT_DOMAIN` | root website domain, if used |
| `WWW_DOMAIN` | `www` alias, if used |
| `PRIMARY_DOMAIN` | VLESS/panel domain |
| `SYNC_DOMAIN` | MTProto/sync/relay domain |
| `WEB_CERT_NAME` | Certbot certificate name |
| `CERT_EMAIL` | email used for Let’s Encrypt |
| `PANEL_PATH` | protected web base path for 3x-ui |
| `XUI_PANEL_PORT` | loopback 3x-ui web port |
| `XRAY_PUBLIC_PORT` | public TLS port, usually `443` |
| `XRAY_LOCAL_PORT` | loopback Xray/VLESS port in HAProxy mode |
| `SITE_BACKEND_PORT` | loopback nginx fallback site port |
| `SYNC_BACKEND_PORT` | loopback nginx sync TLS backend port |
| `MTPROTO_PORT` | loopback MTProto backend port |
| `ALLOW_IPV6_443` | internal compatibility flag; supported installer path keeps it `no` |
| `BASIC_USER` | Basic Auth user for protected panel path |

---

## Manual edits

Manual edits are possible but not recommended unless the operator understands the topology.

After manual edits:

```bash
sudo <prefix>-install
sudo <prefix>-health
```

Do not manually edit secrets inside logs, screenshots, or public issues.
