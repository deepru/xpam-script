# Sites and masking

XPAM Script uses nginx and HAProxy to support HTTPS/TLS routing and local masking/fallback sites.

## Purpose

Masking/fallback sites provide ordinary-looking HTTPS responses for domains used by the XPAM stack. They are not intended to host important production websites.

## Site management

Site management is available from:

```bash
sudo <prefix>-xpam
```

Open `Управление сайтами`.

## Domains

Use placeholder examples in documentation:

```text
example.com
vless.example.com
tg.example.com
```

Do not publish real domains, IP addresses or connection links in public reports.

## Health

After changing sites or DNS, run:

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
```
