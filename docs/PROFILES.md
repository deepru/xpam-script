# Profiles

XPAM Script has three supported installation profiles.

---

## Profile 1: VLESS only, direct TLS

Use this profile when the server needs only VLESS and the protected 3x-ui panel.

Expected shape:

```text
client -> VPS:443 -> Xray/VLESS -> nginx fallback site
```

This profile does not install HAProxy or MTProto.

Direct VLESS keeps Route-only sniffing as its normal baseline for domain routing. If WARP is enabled and later reset, this profile returns to the same direct-VLESS baseline.

Telegram direct notifications and Relay-client mode are available. HTTPS Relay-server mode is not shown for this profile.

---

## Profile 2: VLESS + MTProto, separate subdomains

Use this profile when VLESS and MTProto should be available on separate subdomains.

Expected shape:

```text
client -> VPS:443 -> HAProxy
                  -> Xray/VLESS backend
                  -> MTProto backend
```

This profile supports HTTPS Telegram Relay-server mode through the existing HTTPS/443 surface.

After WARP reset, VLESS sniffing returns to OFF for this HAProxy/MTProto baseline.

---

## Profile 3: Main/root website + VLESS + MTProto

Use this profile when the server also needs a root masking website and `www` redirect in addition to VLESS and MTProto.

Expected shape:

```text
root domain       -> nginx site
www domain        -> redirect to root domain
VLESS domain      -> HAProxy -> Xray/VLESS backend
MTProto domain    -> HAProxy -> MTProto backend
```

This is the fullest public profile. It also supports HTTPS Telegram Relay-server mode through the existing HTTPS/443 surface.

After WARP reset, VLESS sniffing returns to OFF for this HAProxy/MTProto baseline.
