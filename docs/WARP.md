# WARP

WARP support in XPAM Script is optional.

The implementation is based on the 3x-ui/Xray WireGuard outbound model, not `warp-cli`.

---

## Why not `warp-cli`

XPAM Script avoids system-wide `warp-cli` because a full-system WARP route can unexpectedly change:

- SSH reachability;
- package manager behavior;
- DNS behavior;
- certificate issuance paths;
- service-to-service connectivity.

Instead, WARP is treated as an Xray outbound that can be used selectively through Xray routing.

---

## Required operator action

Before using the WARP menu, the operator should create a WARP/WireGuard outbound in 3x-ui.

Then XPAM Script can normalize and adjust it.

---

## What XPAM Script changes

The script detects a WARP-like Xray outbound config and normalizes:

- outbound tag;
- MTU;
- workers;
- IPv4 behavior;
- kernel TUN behavior;
- peer allowed IPs;
- persistent keepalive;
- default YouTube-oriented routing rule when missing;
- VLESS sniffing Route only when needed for domain routing.

The default goal is a controlled IPv4 WARP outbound through Xray, not a full-server VPN.

XPAM Script does not generate Cloudflare WARP reserved bytes. If the 3x-ui WARP generator creates `reserved=[]`, XPAM Script preserves that state and shows a warning in deep health.

---

## Reserved bytes

Cloudflare WARP profiles normally include 3 reserved bytes/clientid. A profile without them may still work, but a profile with valid reserved bytes is preferable.

XPAM Script:

- keeps reserved bytes if they are already present;
- does not copy reserved bytes from another server;
- does not invent `0,0,0` values;
- reports `OK` when reserved bytes are present and valid;
- reports `WARN` when a Cloudflare WARP outbound lacks valid reserved bytes.

If a future 3x-ui version starts generating valid reserved bytes again, XPAM Script will automatically report `OK` without requiring a separate XPAM update.

---

## Routing

XPAM Script adds or restores a default YouTube-oriented routing rule.

Operators may manually add their own domains or IP ranges in 3x-ui/Xray routing. This does not inherently break XPAM Script. Health checks only verify that routing rules to `outboundTag=warp` exist when WARP is configured; route contents are user-managed.

---

## Health behavior

If WARP is not configured, health treats missing `wg0` as acceptable. WARP is optional.

If WARP is configured, health checks the safe technical shape of the outbound and confirms that the system default route and system DNS are not accidentally moved through WARP.

If the SSH session is connected through the same VLESS/Xray path, restarting 3x-ui/Xray during WARP normalization can disconnect the SSH session. This does not mean the server is broken; reconnect and run:

```bash
sudo <prefix>-health
```
