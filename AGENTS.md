# XPAM Script agent/developer guardrails

XPAM Script is a security-sensitive Bash automation toolkit for clean Ubuntu 24.04 and Debian 12 VPS servers.

## Non-negotiable service invariants

- In `vless_direct`, public TCP/443 is Xray/3x-ui VLESS, not nginx and not HAProxy.
- In MTProto profiles, public TCP/443 is HAProxy TCP mode with SNI routing.
- HAProxy routes `SYNC_DOMAIN` to `mtprotoproxy` on `127.0.0.1:MTPROTO_PORT`.
- HAProxy default backend routes to Xray on `127.0.0.1:XRAY_LOCAL_PORT`.
- Xray VLESS fallback must point to nginx on `127.0.0.1:SITE_BACKEND_PORT`.
- MTProto mask backend must be nginx on `127.0.0.1:SYNC_BACKEND_PORT ssl`.
- 3x-ui panel must listen only on `127.0.0.1:XUI_PANEL_PORT`.
- Public panel access must go through `https://PRIMARY_DOMAIN/PANEL_PATH/` and nginx Basic Auth.
- Do not enable PROXY protocol unless HAProxy, Xray and nginx fallback are all changed together.
- Do not regenerate MTProto secrets or VLESS UUIDs on repeated runs.
- Do not remove `/etc/x-ui/x-ui.db`, `/etc/letsencrypt`, `/etc/nginx`, `/etc/haproxy`, `/opt/mtprotoproxy/config.py`, `/root/secure-notes` or WARP backup data during cleanup.
- `certbot.timer` must remain enabled, and TCP/80 must remain available for ACME HTTP-01 renewal.
- Weekly maintenance must not restart HAProxy/MTProto/x-ui unless configuration or certificates actually changed.

## WARP rules

- WARP in XPAM Script is only a 3x-ui/Xray WireGuard outbound.
- Do not install or enable system-wide `warp-cli`.
- Do not route server default traffic or system DNS through WARP.
- If WARP is absent, health must treat it as optional.
- If WARP is present, validate it without exposing private keys, reserved values, or license keys.

## User-facing language

- User-facing menu text, warnings, summaries, Telegram reports and instructions should be in Russian.
- Technical tokens and commands must not be translated: `yes`, `no`, `systemctl`, service names, file paths, environment variables, profile names and command names stay as-is.
- If exact confirmation is required, write in Russian but require the exact English token, for example: `Введите ровно: yes`.

## Development rules

- Preserve one-command bootstrap UX.
- Prefer safe/idempotent `ensure_*` behavior: read current state, compare desired state, change only when necessary.
- Never print secrets, VLESS links, MTProto secrets, Telegram tokens, WARP keys, private keys or relay tokens to installer logs.
- Preserve IPv4-first behavior; do not add public IPv6 TCP/443 unless explicitly requested.
- Run `bash -n` on changed shell scripts and rendered templates.
