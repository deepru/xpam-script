# Telegram notifications

Telegram notifications are separate from Telegram proxy / MTG.

- **Telegram proxy / MTG** is a user connectivity feature.
- **Telegram notifications** are XPAM operational notifications through a bot or relay flow.

## Security

Bot tokens, relay tokens and chat identifiers are sensitive. Do not publish them in issues or logs.

## Management

Notification management is available from:

```bash
sudo <prefix>-xpam
```

Open `Telegram-уведомления`.

## Troubleshooting

If notifications fail, verify token configuration, network access and XPAM health:

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
```


## Separation from 3x-ui Telegram notifications

XPAM Telegram notifications are XPAM-owned health/maintenance/update alerts. They are separate from 3x-ui panel Telegram notifications introduced by upstream 3x-ui as part of its notification event bus.

Also keep terminology separate:

- XPAM Telegram proxy / MTG is the user connection feature that produces a `tg://proxy?...` link.
- XPAM Telegram notifications are optional XPAM operational alerts.
- 3x-ui Telegram notifications are panel notifications sent by 3x-ui through Telegram Bot API.

XPAM does not enable or manage the upstream 3x-ui notification event bus.
