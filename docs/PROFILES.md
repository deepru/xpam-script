# Deployment profiles

XPAM Script supports three profiles.

---

## `vless_direct`

Use when only VLESS/Xray is needed.

Characteristics:

- no MTProto;
- no HAProxy;
- simplest TLS layout;
- public `443` is used directly by Xray/VLESS;
- fallback website is provided by nginx.

---

## `subdomains_mtproto`

Use when VLESS and MTProto are needed on separate domains.

Characteristics:

- HAProxy listens on `443`;
- VLESS domain routes to Xray/VLESS backend;
- MTProto domain routes to MTProto backend;
- nginx provides web surface and relay-compatible HTTPS behavior.

---

## `root_mtproto`

Use when the server should also expose a normal root website.

Characteristics:

- root domain website;
- `www` redirect to root domain;
- separate VLESS/panel domain;
- separate MTProto/sync domain;
- HAProxy routes by SNI.

This is the most complete profile.
