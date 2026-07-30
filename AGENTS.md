# Maintainer notes

This file describes public maintainer rules for XPAM Script.

## Public architecture

XPAM Script is documented as a VPS automation project for:

- VLESS through 3x-ui/Xray;
- Telegram proxy / MTG through 3x-ui;
- nginx + HAProxy + TLS routing;
- DoubleHop Mode;
- WARP through 3x-ui/Xray;
- an optional spare VLESS transport (xhttp/grpc) on a separate domain;
- health/deep-health;
- repair and weekly maintenance;
- safe self-update.

Use the current public terminology consistently: **Telegram proxy / MTG**, **Telegram link**, **DoubleHop Mode**, `sudo <prefix>-xpam`, `sudo <prefix>-links`.

## Command surface invariants

- `sudo <prefix>-xpam` is the primary management interface.
- `sudo <prefix>-links` is the safe connection summary.
- `sudo <prefix>-links` prints sensitive connection data.
- VLESS and Telegram links shown by `sudo <prefix>-links` must be generated from the current 3x-ui configuration.
- Public documentation should not reference removed user-facing command names from older releases.

## DoubleHop invariants

- XPAM manages DoubleHop on the Entry server only.
- The Exit server is prepared separately by the user.
- XPAM uses a user-provided Exit VLESS link.
- Enabling, changing or disabling DoubleHop must not change existing Entry-side VLESS or Telegram links.
- Manual Telegram proxy / MTG secret rotation in 3x-ui must be reflected by `sudo <prefix>-links` and must not be reverted by health, repair or weekly maintenance.
- Public documentation must not imply automatic Exit-server management.

## Update invariants

Safe self-update must follow this model:

```text
release metadata -> archive + sha256 -> SHA256 verification -> staging extract -> preflight -> backup -> apply -> postcheck -> rollback if needed
```

The updater must not print live connection links, tokens or private keys in logs.

## Documentation safety

Public files must not contain real project/operator data, including:

- real domains;
- real IP addresses;
- real VLESS links;
- real Telegram links;
- UUIDs or tokens;
- mock URLs;
- local operator paths;
- internal validation logs.

Use neutral placeholders such as:

```text
example.com
vless.example.com
tg.example.com
<server-ip>
<prefix>
<exit-vless-link>
<redacted>
```

## Release documentation

State supported platforms as **Ubuntu and Debian**, with no version numbers. That matches what the code actually enforces: `require_os` accepts a distribution by `ID` only and applies no version floor or ceiling, and health checks deliberately avoid pinning to a `VERSION_ID` so newer releases cannot false-FAIL. Naming specific releases would therefore understate real compatibility, and it decays — a pair of version numbers that reads as "current" today reads as "abandoned" once the next releases ship, while the code keeps working. Supported platforms are a **product property**: state them once (README, `docs/`, `TESTING.md`), not per release.

Do not expose internal stage names, validation stage matrices, or "what we tested against" as the public testing story — that includes third-party component versions such as the 3x-ui or Xray build a release happened to be developed on. The user's concern is whether the product works on their server, not our test log. Kit provenance belongs in `BUILD_INFO`, the changelog and git history.

Dated version numbers are fine in two places: historical changelog entries (a past release legitimately describes what it was verified against) and examples inside an error message aimed at someone who has already hit the problem.

## Writing rules for public documents

These exist because every one of them was broken at least once, and the result reached users. Apply
them to anything published in the repository: `README*.md`, `docs/`, `RELEASE_NOTES_*.md`,
`SECURITY.md`, `TESTING.md`, `.github/` templates.

### Know who the reader is, and never mix two readers in one file

Every public file is written for **the operator running the product**, not for whoever builds it.
Maintainer material — build gates, release checklists, "use placeholders in examples", terminology
instructions, invariants — belongs in this file or in `handoff/`, never in `docs/`.

The reliable symptom is the word **must** or **should** aimed at the software: "the updater must
verify SHA256", "bootstrap download should use HTTP/1.1". That is a specification. The operator needs
the indicative: *the updater verifies the checksum and rolls back if the result is not healthy*. If a
sentence would still make sense in a requirements document, it is in the wrong file.

### One thing, one name

Pick the name the product itself uses on screen, and use only that name everywhere. The spare
transport once had five names across README, the guide and the release notes ("запасной способ
подключения", "запасной вход", "запасное подключение", "альтернативный транспорт", "запасной
транспорт"), which is what a text assembled in pieces and never re-read looks like. Current terms:

| Thing | Name | Not |
|---|---|---|
| The optional second VLESS transport | **запасной транспорт** / spare transport | «запасной способ подключения», «запасной вход», «альтернативный транспорт» |
| Telegram proxy | **Telegram proxy / MTG** | MTProto proxy, mtg |
| DoubleHop | **DoubleHop Mode** | double hop, второй хоп |
| The decoy websites | **сайты-маскировки** / masking sites | обманки, заглушки |

### Every factual claim comes from the code

Read the source before you write behaviour, and re-read it before you change a document that
describes behaviour. Not from memory, not from an older version of the document, not from a live box
that may be running a different build. Menu items, command names, flags, defaults, file paths and
schedules must be verified against `scripts/` and `templates/` at the moment of writing.

Two real failures behind this rule: the guide told the user to pick menu item `0`, which is Exit,
because the steps had been numbered before the menu was; and the guide and `docs/MAINTENANCE.md` both
promised the server never reboots on its own, months after weekly maintenance started rebooting it.
Cross-references are the same class of hazard — when a step number, menu label or flag changes, grep
the whole public tree for it in the same commit.

### No decoration

No emoji in headings or in the table of contents. Emoji are acceptable only as column icons inside a
feature table, where they carry no meaning that the text does not already carry. No "big release", no
"полное тестирование", no claims about how fast or easy something is.

### Say a thing once

Facts that appear in more than one file drift apart. The secrets list lives in `SECURITY.md`; every
other document links to it instead of restating it. The supported platforms live in the README. What
a command does lives in the guide. When you need the same fact twice, link.

## CHANGELOG and release notes are different documents

`CHANGELOG.md` is not required by GitHub — nothing reads it automatically — and it is kept
deliberately: it is the record that makes it possible to check a release body against what actually
shipped. Keep it complete, at one to three sentences per entry. Forensic detail (measurements, "how
we proved it", the debugging story) belongs in the commit message and in `handoff/`, which already
carry it.

`RELEASE_NOTES_<version>_RU.md` is posted verbatim as the GitHub release body and is the most public
artefact of a release. **It is a strict subset of the changelog, filtered by one question: does this
change anything for someone running the product?**

Never goes into release notes:

- **Anything the user never experienced.** A bug introduced and fixed inside the same development
  cycle was never in a release, so for the user it did not exist. Listing such fixes makes a new
  feature look shaky and pads the notes with non-events. v1.4.0 first drafted six "fixes" of which
  five were of this kind, while three genuine fixes to shipped bugs were missing.
- **Build, CI and gate work.** Required-file lists, smoke tests, build naming, `BUILD_INFO`.
- **Internal reasoning and measurements**, refactors, renamed internal files, function names.
- **Third-party versions we tested against** (3x-ui, Xray), and platform version numbers.

Always goes in: what changed for the operator, and anything that can surprise them — removed or
renamed commands, changed defaults, and any new behaviour that acts on its own (an automatic reboot
is the current example). Plus the upgrade path and the warning not to publish `<prefix>-links`
output.
