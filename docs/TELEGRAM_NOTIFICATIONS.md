# Telegram notifications

Telegram notifications are optional and are used for operational alerts.

They are mainly intended for:

- failed weekly maintenance;
- failed health check;
- manual reboot required.

They are not intended as chatty success reports.

---

## Mode 1: Direct

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

## Mode 3: Relay server

This server receives HTTPS notification payloads from other XPAM Script servers and forwards them to Telegram.

Use this mode when:

- you operate multiple servers;
- one server can access Telegram API directly;
- other servers should not store Telegram bot token.

The Relay server:

- uses the existing HTTPS/443 surface;
- does not open a separate public port;
- uses nginx and a local Unix socket worker;
- stores the relay token securely.

---

## Mode 4: Verify existing settings

This mode checks saved Telegram settings without reconfiguring them.

---

## Mode 5: Skip

Telegram notifications can be skipped. Health and maintenance still work locally.
