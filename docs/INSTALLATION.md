# Installation

XPAM Script expects a fresh Ubuntu 24.04 LTS or Debian 12 VPS.

## Required preparation

Before running XPAM Script, prepare:

1. root access to the VPS;
2. confirmed SSH key login;
3. a domain name;
4. access to DNS zone management;
5. DNS `A` records pointing the required domains to the VPS IPv4 address.

Do not start step `0` until SSH key login works in a separate SSH session.

## GitHub bootstrap installation

XPAM Script is installed through the GitHub bootstrap command:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

The bootstrap installer downloads the published release archive, downloads the matching SHA256 file, verifies the archive, extracts it and starts `install.sh`.

## Step 0

Step `0` configures SSH security and creates the command prefix.

The prefix determines the final command names:

```text
sudo <prefix>-install
sudo <prefix>-health
sudo <prefix>-links
sudo <prefix>-vless
sudo <prefix>-telega
sudo <prefix>-netdiag
sudo <prefix>-repair
```

After step `0`, continue through:

```bash
sudo <prefix>-install
```

## Step 1

Step `1` installs and configures the server. It may require a reboot. If a reboot is requested:

```bash
sudo reboot
```

After reconnecting by SSH key:

```bash
sudo <prefix>-install
```

Then choose step `1` again to continue.

## Post-install validation

Run:

```bash
sudo <prefix>-health
```

The health check should end with a healthy status. For ordinary usage, weekly maintenance is configured automatically and does not need to be run manually.
