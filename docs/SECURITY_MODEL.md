# Security model

XPAM Script is designed for a single-purpose VPS operated by root or a trusted administrator.

---

## SSH

Step `0` requires confirmed SSH key access before hardening SSH.

The script:

- checks `/root/.ssh/authorized_keys`;
- disables SSH password authentication;
- disables keyboard-interactive authentication;
- disables X11 forwarding;
- keeps TCP forwarding enabled.

TCP forwarding remains enabled because it can be operationally useful for SSH tunnels.

---

## Firewall

UFW policy is rebuilt by XPAM Script.

Expected public IPv4 rules:

```text
22/tcp
80/tcp
443/tcp
```

IPv6 public 443 is not expected unless explicitly allowed.

---

## Local-only backends

The following should not be publicly exposed:

- 3x-ui panel backend;
- Xray local backend in HAProxy mode;
- nginx fallback backend;
- nginx sync backend;
- MTProto backend.

The health check validates expected loopback listeners.

---

## Secrets

Secrets are stored under:

```text
/root/secure-notes
```

Never publish this directory.

Sensitive values include:

- VLESS links;
- MTProto links;
- Telegram tokens;
- Relay tokens;
- WARP keys;
- certificate private keys;
- Basic Auth passwords;
- 3x-ui admin password.

---

## Limitations

XPAM Script cannot protect against:

- root compromise;
- a malicious provider;
- registrar or DNS account compromise;
- malicious upstream packages;
- unsafe manual changes;
- publishing secrets by mistake.
