# Sites and masking

XPAM Script uses nginx and HAProxy to support HTTPS/TLS routing and local masking/fallback sites.

## Purpose

Masking sites provide ordinary-looking HTTPS responses for the domains used by the XPAM stack, so a
casual visitor or a network probe sees a normal website rather than a bare or suspicious endpoint.

## Default sites

By default XPAM generates a small, self-contained **product landing** site for each domain — a
plausible page for a minimal technical product (landing, docs, license, 404, plus robots.txt and
sitemap.xml). The product, the layout and the styling are all derived from the domain name, so every install
looks different — not merely recoloured, but laid out differently — and no two domains of one server
look the same. The pages carry restrained CSS motion (and honour `prefers-reduced-motion`); they
contain no invented metrics, statuses or dates and do not change over time. The same domain always
regenerates the same site, so repair and reset are stable. You do not need to edit anything for
masking to work.

When the optional spare transport is enabled, its domain gets its own decoy site as well.

## Site management

From `sudo <prefix>-xpam` → `Управление сайтами` you can:

- see the site folders and the rules for editing them;
- **upload your own site** — place files in the domain's web root and apply them;
- **restore the standard sites** — regenerate the default pages at any time.

## Bring your own site

If you place your own static site in a domain's web root (`/var/www/<domain>/`, containing an
`index.html`), XPAM keeps it and does not overwrite it on install or repair. Real, self-hosted
content that you actually own is the most convincing masking of all.

## Health

After changing sites or DNS, run:

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
```
