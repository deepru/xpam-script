# Security policy

XPAM Script is a server automation tool that handles sensitive operational data. Treat issue reports, logs, and screenshots with care.

---

## Supported versions

| Version | Status |
|---|---|
| 1.0.8 | Supported baseline |
| older versions | Unsupported |

---

## Reporting security issues

If you find a security issue, do not open a public issue with secrets, tokens, domains, IP addresses, or private logs.

Recommended report format:

```text
Subject: XPAM Script security issue

Version:
OS:
Profile:
Short description:
Impact:
Steps to reproduce:
Redacted logs:
```

Replace the contact placeholder before publishing this repository:

```text
stas.khramov.github@gmail.com
```

---

## Never publish these values

Before posting logs or screenshots, redact:

```text
VLESS links
MTProto links
Telegram bot tokens
Telegram chat IDs, if private
Telegram HTTPS Relay tokens
WARP private keys
certificate private keys
/root/secure-notes/*
/etc/xpam-script/config.env
real domains, if private
public IP addresses, if private
SSH public keys, if you do not want them tied to your identity
SSH private keys, always
```

---

## Expected security model

XPAM Script assumes:

- root access to a fresh VPS;
- operator-controlled domain and DNS zone;
- SSH key access confirmed before password login is disabled;
- only one operator or a small trusted operator group;
- no untrusted shell users on the VPS.

The script does not protect against:

- a compromised root account;
- malicious upstream packages;
- a compromised DNS account;
- a compromised domain registrar;
- malicious VPS provider access;
- improper manual changes after installation.

---

## Operational precautions

Use the built-in commands instead of hand-editing service files when possible:

```text
sudo <prefix>-install
sudo <prefix>-health
sudo <prefix>-links
sudo <prefix>-vless
sudo <prefix>-telega
```

Do not manually publish `/root/secure-notes`, `/etc/xpam-script/config.env`, or config backups.
