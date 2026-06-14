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
