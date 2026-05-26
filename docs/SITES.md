# Websites and fallback surface

XPAM Script installs simple static websites for public HTTP/HTTPS behavior.

These websites are not just decoration. They provide normal web responses for domains that are also used by TLS/SNI-based services.

---

## Default web roots

Depending on the selected profile, web roots may include:

```text
/var/www/<primary-domain>      VLESS / panel masking site
/var/www/<root-domain>         root website
/var/www/<sync-domain>         MTProto / relay masking site
```

The `www` domain in the root profile is normally a redirect and does not need a separate website directory.

---

## What can be changed

Operators may replace static website files:

- `index.html`;
- CSS;
- JS;
- images;
- static pages.

Use the website management menu to see the exact paths and verify uploaded files.

---

## What should not be changed casually

Do not occupy or remove reserved paths used by XPAM Script, nginx, HAProxy, or 3x-ui.

Do not break:

- ACME challenge locations;
- protected 3x-ui base path;
- Telegram Relay path, if configured;
- nginx fallback behavior;
- HAProxy SNI assumptions.

After uploading custom websites, run:

```bash
sudo <prefix>-install
```

Then choose website management and verify.
