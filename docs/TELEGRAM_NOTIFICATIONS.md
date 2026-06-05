# Telegram notifications

Telegram notifications are optional and are used for operational alerts.

They are mainly intended for:

- failed weekly maintenance;
- failed health check;
- manual reboot required.

They are not intended as chatty success reports.

---

## Mode 1: Direct notifications

The VPS sends messages directly to Telegram Bot API.

Use this mode when:

- the server has direct network access to Telegram API;
- the operator manages one server;
- the bot token can be stored on this server.

Requires:

- Telegram bot token from BotFather;
- personal chat with the bot.

---

## Mode 2: Relay client

The VPS sends notification payloads to another XPAM Script server acting as HTTPS Relay.

Use this mode when:

- this server cannot access Telegram API directly;
- another XPAM server can access Telegram;
- you do not want to store the Telegram bot token on this server.

Requires:

- Relay URL from the Relay server;
- Relay token from the Relay server.

---

## Mode 3: HTTPS Relay server

This server receives HTTPS notification payloads from other XPAM Script servers and forwards them to Telegram.

Use this mode when:

- you operate multiple XPAM servers;
- one server can access Telegram API directly;
- other servers should not store Telegram bot token.

The Relay server:

- uses the existing HTTPS/443 surface;
- does not open a separate public port;
- stores the relay token securely;
- is checked by health/deep-health.

Relay-server mode is shown only for profiles that can safely host it through the HAProxy/MTProto HTTPS surface. Direct VLESS profile servers can still use direct notifications or Relay-client mode, but they do not offer Relay-server mode in the menu.

---

## Verify existing settings

This mode checks saved Telegram settings without reconfiguring them.

---

## Skip

Telegram notifications can be skipped. Health and maintenance still work locally.

---

## Secrets

Do not publish:

- bot token;
- Relay token;
- Relay URL if it contains a secret path;
- screenshots that show Telegram configuration values.
