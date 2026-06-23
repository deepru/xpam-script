## Summary

Describe the change and the affected XPAM area.

## Checklist

- [ ] Public docs use current v1.3.6 terminology: VLESS, Telegram proxy / MTG, Telegram link, DoubleHop Mode.
- [ ] Public docs use `sudo <prefix>-xpam` and `sudo <prefix>-links` for user-facing commands.
- [ ] No real domains, IP addresses, UUIDs, live connection links, tokens, mock URLs or local operator paths are included.
- [ ] README / CHANGELOG / TESTING / release notes were updated if user-facing behavior changed.
- [ ] Runtime changes, if any, were tested with `sudo <prefix>-health` and `sudo <prefix>-health --deep`.
- [ ] Safe self-update behavior is preserved if update-related files were changed.
- [ ] DoubleHop Mode invariants are preserved if routing-related files were changed.

## Notes

Use placeholders such as `example.com`, `<server-ip>`, `<prefix>`, `<exit-vless-link>` and `<redacted>` in public examples.
