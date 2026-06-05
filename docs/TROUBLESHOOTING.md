# Troubleshooting

Start with:

```bash
sudo <prefix>-health
systemctl --failed --no-pager
```

---

## SSH access

If SSH key login does not work, do not run step `0`.

Fix:

```bash
mkdir -p /root/.ssh
chmod 700 /root/.ssh
nano /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

The public key must be one line.

---

## DNS / certificate failures

Check that every required domain has an `A` record pointing to the VPS IPv4 address.

XPAM Script is IPv4-first. Make sure XPAM domains have A records pointing to the VPS IPv4 address and do not have AAAA records. Public IPv6 installation is not supported by XPAM Script.

Run:

```bash
dig +short example.com
dig +short vless.example.com
dig +short tg.example.com
```

---

## Debian 12 networking.service failed

Some VPS images generate problematic `/etc/network/interfaces.d/50-cloud-init` files.

Symptoms may include:

```text
networking.service failed
RTNETLINK answers: File exists
sd_bus_open_system: No such file or directory
```

This is usually provider image/cloud-init/networking state, not an XPAM service failure.

Recommended approach:

1. inspect `systemctl status networking`;
2. inspect `/etc/network/interfaces`;
3. inspect `/etc/network/interfaces.d/*`;
4. keep DNS policy under systemd-resolved;
5. avoid duplicate static route creation;
6. rerun health after fixing networking state.

Do not blindly copy networking fixes between providers. Network interface names and gateway policy differ.

---

## VLESS does not connect

Check:

```bash
sudo <prefix>-health
sudo <prefix>-vless
```

Verify:

- domain points to VPS;
- certificate contains expected DNS names;
- Xray listens on expected port;
- HAProxy is healthy, if used;
- client link uses the public domain and port `443`.

---

## MTProto does not connect

Check:

```bash
sudo <prefix>-health
sudo <prefix>-tg
```

Verify:

- MTProto profile is enabled;
- MTProto domain points to VPS;
- HAProxy routes SNI correctly;
- local MTProto backend is reachable;
- user secret was not regenerated without updating the client.

---

## Telegram notifications do not arrive

Check mode:

- Direct mode requires Telegram Bot API access from this VPS.
- Relay client mode requires a valid Relay URL and Relay token.
- Relay server mode requires working bot token and relay worker.

Run the menu:

```bash
sudo <prefix>-install
```

Then choose Telegram notifications.

---

## Health fails after a 3x-ui update

3x-ui is an upstream component and may be updated through its own panel.

After updating 3x-ui, run:

```bash
sudo <prefix>-health
```

If health reports a problem, run:

```bash
sudo <prefix>-repair
sudo <prefix>-health
```

Do not edit the 3x-ui database or generated Xray config by hand unless you understand the XPAM profile contract.

---

## MTProto works in one network but not another

If health is OK and MTProto works from one client or network but fails from another, check the external path before changing the server.

Useful checks:

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
```

Also test:

- the MTProto health URL in a browser;
- another network, such as Wi-Fi versus LTE;
- VLESS on the same network;
- a freshly added MTProto proxy entry in the Telegram client.

If the server-side checks are healthy and the problem appears only through one network or operator, it may be an external route or filtering issue rather than a broken XPAM installation.

---

## WARP reset completed, but sniffing is still enabled

This depends on the active profile.

For direct VLESS profile, Route-only sniffing is the normal baseline. Seeing it enabled after WARP reset is expected.

For HAProxy/MTProto profiles, WARP reset should return sniffing to OFF.

Run:

```bash
sudo <prefix>-health --deep
```

Deep health reports whether the current sniffing state matches the active profile baseline.
