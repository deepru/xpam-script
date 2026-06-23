# Release process

This checklist is for XPAM Script maintainers.

## Before release

- Confirm the runtime archive and SHA256.
- Confirm README, release notes, changelog and testing documentation are updated.
- Confirm public docs use current v1.3.6 terminology.
- Confirm user guide files are either updated or intentionally left for a separate pass.
- Confirm no public file contains real domains, IP addresses, UUIDs, live connection links, tokens, mock URLs, local paths or internal validation logs.

## Public testing wording

Use user-facing wording such as:

```text
Проверено на Ubuntu 24.04 LTS и Debian 12: установка, управление сервером, VLESS, Telegram proxy / MTG, DoubleHop Mode, диагностика, восстановление и безопасное обновление.
```

Do not expose internal validation stage names as the public release story.

## Release assets

For GitHub Releases, publish:

- release archive;
- `.sha256` file;
- release notes;
- installation command block.

Do not publish private test archives or local mock update assets.

## Leak audit

Run a grep audit over public markdown/YAML files for:

- live domains;
- live IP addresses;
- VLESS links;
- Telegram links;
- current 3x-ui-sourced VLESS/Telegram link output;
- UUIDs;
- tokens;
- mock URLs;
- local paths;
- internal validation logs.

All examples should use neutral placeholders such as `example.com`, `<prefix>`, `<server-ip>` and `<redacted>`.
