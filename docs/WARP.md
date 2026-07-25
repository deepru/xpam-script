# WARP through 3x-ui/Xray

XPAM Script can configure WARP as an optional outbound through 3x-ui/Xray.

This is not a system-wide VPN for the whole VPS. It is an Xray routing/outbound feature managed from XPAM.

## Management

Open:

```bash
sudo <prefix>-xpam
```

Then use `WARP через 3x-ui/Xray`.

Setup is automatic: XPAM generates the WireGuard keys, registers the WARP account with Cloudflare
through 3x-ui, creates the WARP outbound, restores the YouTube routing preset and restarts Xray.
You do not need to open the 3x-ui panel.

The menu also offers:

- `Сменить WARP-IP` — ask Cloudflare for a new egress address. VLESS/Telegram links do not change.
- `Отключить WARP` — remove the XPAM-managed outbound, its routing rules and the stored WARP account.

If the server cannot reach Cloudflare, registration fails with a short message and the configuration
is left unchanged.

## IPv4-only

The WARP outbound is kept IPv4-only, matching the public layout. Changing the WARP IP from the 3x-ui
panel adds Cloudflare's IPv6 address, so prefer the XPAM menu; `repair` restores the expected values
if that happens, and `deep-health` warns when the panel's scheduled WARP IP rotation is enabled.

## Health

After enabling, disabling or changing WARP, run:

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
```

## WARP and DoubleHop

They are separate features and are configured independently, but they do interact: DoubleHop routes
**all** VLESS traffic to the Exit server, so while it is enabled for VLESS the WARP rules never
match and WARP is effectively unused. Nothing is lost — the WARP configuration is kept and takes
effect again once DoubleHop is switched off — and the menu says so before enabling DoubleHop.

In `Telegram only` mode VLESS stays direct, so WARP keeps working there.
