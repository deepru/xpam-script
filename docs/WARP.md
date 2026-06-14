# WARP through 3x-ui/Xray

XPAM Script can configure WARP as an optional outbound through 3x-ui/Xray.

This is not a system-wide VPN for the whole VPS. It is an Xray routing/outbound feature managed from XPAM.

## Management

Open:

```bash
sudo <prefix>-xpam
```

Then use `WARP через 3x-ui/Xray`.

## Health

After enabling, disabling or changing WARP, run:

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
```

## Notes

WARP and DoubleHop are separate routing concepts. Do not assume that changing one automatically changes the other.
