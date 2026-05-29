# XPAM Script v1.1.1

Focused production hotfix for IPv4-only public listener correctness.

## Fixed

- Direct VLESS profile now binds the public Xray/VLESS inbound to the detected public IPv4 address instead of relying on an empty/wildcard listen value.
- Existing direct VLESS installations can be normalized through repair without changing VLESS UUIDs, clients, certificates, fallback, WARP, Telegram Relay, nginx, HAProxy or MTProto configuration.
- Health/deep-health now requires a real IPv4 listener for public ports and fails if XPAM-managed public ports are exposed through IPv6 wildcard/public listeners.
- TLS validation for direct VLESS now checks the detected public IPv4 endpoint instead of assuming localhost can reach the public listener.
- Service hygiene apply now clears stale failed-state only for XPAM-managed hygiene units after they are stopped/disabled/masked, preventing false `systemctl --failed` health failures on some provider images.
- External Proxy is now normalized for XPAM-managed VLESS inbounds in all profiles so 3x-ui generated links consistently use the public domain and port.

## Not changed

- No change to 3x-ui install strategy.
- No change to HAProxy/MTProto routing.
- No change to nginx fallback layout.
- No change to WARP, Telegram Relay, DNS safe mode or production cleanup.
- IPv6 is not globally disabled; it remains allowed for local/internal use, but XPAM-managed public 22/80/443 must remain IPv4-only.
