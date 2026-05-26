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

The script detects WARP-like Xray outbound config and normalizes:

- outbound tag;
- MTU;
- workers;
- IPv4 behavior;
- kernel TUN behavior;
- peer allowed IPs;
- persistent keepalive;
- YouTube routing rule.

The default goal is a controlled IPv4 WARP outbound through Xray, not a full-server VPN.

---

## Routing

XPAM Script adds or restores a default YouTube-oriented routing rule.

Operators may manually add their own domains or IP ranges in 3x-ui/Xray routing. This does not inherently break XPAM Script.

If WARP routing becomes confusing, the operator can use the XPAM Script WARP menu to restore the expected defaults.

---

## Health behavior

If WARP is not configured, health treats missing `wg0` as acceptable. WARP is optional.
