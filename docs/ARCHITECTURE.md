# Architecture

XPAM Script builds a controlled VPS service layout around three principles:

1. keep the public port surface small;
2. expose backends only on loopback;
3. verify the runtime state continuously.

---

## Public surface

The expected public TCP surface is:

```text
22/tcp   SSH
80/tcp   HTTP / ACME HTTP-01 / redirect
443/tcp  HTTPS/TLS service surface
```

No separate public MTProto, relay, panel, or Xray management ports are expected.

---

## Backend isolation

Backends are expected to bind to `127.0.0.1`.

```text
3x-ui web panel       127.0.0.1:<XUI_PANEL_PORT>
Xray/VLESS            127.0.0.1:<XRAY_LOCAL_PORT>
nginx site backend    127.0.0.1:<SITE_BACKEND_PORT>
nginx sync backend    127.0.0.1:<SYNC_BACKEND_PORT>
MTProto backend       127.0.0.1:<MTPROTO_PORT>
```

The health check validates this exposure model.

---

## Direct VLESS profile

In `vless_direct`, Xray/VLESS can own the public TLS endpoint directly. nginx provides fallback website behavior through Xray fallback.

```text
client
  -> VPS:443
      -> Xray/VLESS
          -> nginx fallback site on loopback
```

This is the simplest profile and does not install HAProxy or MTProto.

---

## HAProxy / MTProto profiles

In MTProto profiles, HAProxy listens on public `443/tcp`.

```text
client
  -> VPS:443
      -> HAProxy TCP frontend
          -> MTProto backend, when SNI matches MTProto domain
          -> Xray/VLESS backend, default path
```

This allows the server to keep one public TLS port while separating roles by domain/SNI.

---

## Certificate model

XPAM Script uses Let’s Encrypt certificates through Certbot.

Depending on the profile, it issues:

- a certificate for the VLESS/panel domain;
- a unified root/www/VLESS certificate;
- a certificate for the MTProto/sync domain.

Certificate consistency is checked against the runtime endpoints with OpenSSL.

---

## Runtime install model

At install time, XPAM Script writes:

```text
/etc/xpam-script/config.env
/opt/xpam-script
/usr/local/sbin/<prefix>-install
/usr/local/sbin/<prefix>-health
/usr/local/sbin/<prefix>-links
/usr/local/sbin/<prefix>-vless
/usr/local/sbin/<prefix>-telega
/usr/local/sbin/<prefix>-weekly-maintenance.sh
```

The weekly command exists as a system maintenance entry point. It is not promoted as a normal user-facing command.

---

## Data and secrets

Sensitive runtime data is stored under:

```text
/root/secure-notes
```

Configuration backups are stored under:

```text
/root/config-backups
```

These directories must not be committed or published.
