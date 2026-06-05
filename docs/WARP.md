# WARP

WARP support in XPAM Script is optional.

XPAM Script uses the 3x-ui/Xray WireGuard outbound model. It does not install `warp-cli` and does not turn the VPS into a system-wide WARP/VPN server.

---

## How WARP is used

WARP is used as an optional outbound inside Xray. It can be used through Xray routing rules while the rest of the server keeps the normal XPAM service layout.

The expected workflow is:

1. create a WARP/WireGuard outbound in the 3x-ui panel;
2. run the XPAM WARP menu;
3. let XPAM check and normalize the XPAM-managed WARP state;
4. run health after the Xray restart.

---

## WARP normalize

After the operator creates WARP in 3x-ui, XPAM can check the managed WARP configuration and bring it to a compatible baseline for the active profile.

Before changing the 3x-ui database, XPAM creates a backup.

XPAM does not change the server default route and does not use WARP as a system-wide VPN. WARP remains an Xray outbound.

---

## WARP disable / reset

XPAM can disable the XPAM-managed WARP state from the WARP menu.

The reset flow is intended for the common case where the operator enabled WARP and later wants to return the server to the normal profile baseline without manually editing 3x-ui internals.

After reset, XPAM restores VLESS sniffing/routing behavior to the active profile baseline:

- direct VLESS profile: Route-only sniffing is the normal baseline;
- HAProxy/MTProto profiles: sniffing returns to OFF.

User-created WireGuard/WARP outbounds outside the XPAM-managed WARP state are not removed by this flow.

---

## Health behavior

WARP is optional. If WARP is not configured, health treats the missing WARP interface as acceptable.

When WARP is configured, deep health checks that the managed WARP state is compatible with the XPAM profile and that the system-level server routing was not accidentally moved through WARP.

If the SSH session is connected through the same VLESS/Xray path, restarting 3x-ui/Xray during WARP normalize or reset can disconnect the SSH session. This does not mean the server is broken. Reconnect and run:

```bash
sudo <prefix>-health
```

---

## What not to do

Do not manually copy WARP keys or low-level WARP values between unrelated servers.

Do not edit generated Xray runtime files as the primary way to configure WARP. Use the 3x-ui panel and the XPAM WARP menu.

If WARP is no longer needed, use the XPAM WARP disable/reset menu instead of removing only one piece of the configuration by hand.
