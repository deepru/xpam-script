#!/usr/bin/env python3
# XPAM Script — deterministic decoy mask-site generator.
# Renders a small, self-contained "product landing" site (index/docs/license/404 +
# favicon/robots/sitemap + assets/style.css) into a target web root, chosen deterministically
# from the domain. Design + rationale: handoff/MASKING_IDEAS.md (section 4b).
#
# Inputs (environment):
#   MASK_DOMAIN      full FQDN of the site (e.g. app.example.com)             [required]
#   MASK_DEST        target directory (e.g. /var/www/app.example.com)          [required]
#   MASK_ROLE        primary|sync|root  (informational; all presets are API-shaped)
#   MASK_PRESET      optional preset id override (empty = deterministic auto)
#   MASK_DIR         directory holding presets.json + palettes.json (default: this file's dir)
#
# No network, no external assets — everything is inlined or same-origin. Deterministic:
# the same domain always yields the same preset + accent (stable across repair/reset).

import hashlib, html, json, os, sys

SELF_DIR = os.path.dirname(os.path.abspath(__file__))
MASK_DIR = os.environ.get("MASK_DIR") or SELF_DIR


def die(msg):
    sys.stderr.write("mask-generate: " + msg + "\n")
    sys.exit(2)


def seed_int(s):
    return int.from_bytes(hashlib.sha256(s.encode("utf-8")).digest()[:8], "big")


def registrable(fqdn):
    parts = [p for p in fqdn.split(".") if p]
    return ".".join(parts[-2:]) if len(parts) >= 2 else fqdn


def esc(s):
    return html.escape(str(s), quote=False)


# --- icon library (inline SVG inner markup; 24x24 viewBox, stroked) ---
ICONS = {
    "sync":   '<path d="M4 12a8 8 0 0 1 13-6.2M20 12a8 8 0 0 1-13 6.2M17 4v3h-3M7 20v-3h3"/>',
    "db":     '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
    "api":    '<path d="M8 3H5a2 2 0 0 0-2 2v3M16 3h3a2 2 0 0 1 2 2v3M8 21H5a2 2 0 0 1-2-2v-3M16 21h3a2 2 0 0 0 2-2v-3M9 12h6M12 9v6"/>',
    "queue":  '<path d="M4 7h16M4 12h16M4 17h16"/><circle cx="7" cy="7" r="0.1"/>',
    "bolt":   '<path d="M13 2L4 14h7l-1 8 9-12h-7l1-8z"/>',
    "stream": '<path d="M3 12h4l2 6 4-14 2 8h6"/>',
    "lock":   '<rect x="4" y="10" width="16" height="10" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
    "layers": '<path d="M12 3l9 5-9 5-9-5 9-5zM3 13l9 5 9-5"/>',
    "box":    '<path d="M21 8v8a2 2 0 0 1-1 1.7l-7 4a2 2 0 0 1-2 0l-7-4A2 2 0 0 1 3 16V8a2 2 0 0 1 1-1.7l7-4a2 2 0 0 1 2 0l7 4A2 2 0 0 1 21 8z"/><path d="M3.3 7L12 12l8.7-5M12 22V12"/>',
    "search": '<circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/>',
    "flag":   '<path d="M5 3v18M5 4h13l-2 4 2 4H5"/>',
    "chart":  '<path d="M4 19h16M7 16v-4M12 16v-8M17 16v-6"/>',
    "shield": '<path d="M12 3l8 3v6c0 5-4 8-8 9-4-1-8-4-8-9V6l8-3z"/>',
    "clock":  '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    "mail":   '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/>',
    "key":    '<circle cx="8" cy="15" r="4"/><path d="M11 12l8-8M17 4l3 3M14 7l2 2"/>',
    "globe":  '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18"/>',
    "filter": '<path d="M3 5h18l-7 8v6l-4-2v-4L3 5z"/>',
    "gauge":  '<path d="M12 13l4-4M4 20a8 8 0 1 1 16 0"/>',
    "retry":  '<path d="M4 4v6h6M20 20v-6h-6M20 8A8 8 0 0 0 6 6M4 16a8 8 0 0 0 14 2"/>',
}
GLYPHS = {
    "cube": '<path d="M12 2L3 7v10l9 5 9-5V7l-9-5z" stroke="currentColor" stroke-width="1.6"/><path d="M12 2v20M3 7l9 5 9-5" stroke="currentColor" stroke-width="1.6" opacity=".5"/>',
    "hex":  '<path d="M12 2l8 4.6v9.2L12 22l-8-4.2V6.6L12 2z" stroke="currentColor" stroke-width="1.6"/><path d="M12 2v20M4 6.6l8 4.6 8-4.6" stroke="currentColor" stroke-width="1.6" opacity=".5"/>',
    "ring":     '<circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.6"/><circle cx="12" cy="12" r="4" stroke="currentColor" stroke-width="1.6" opacity=".5"/>',
    "diamond":  '<path d="M12 2l7 10-7 10-7-10 7-10z" stroke="currentColor" stroke-width="1.6"/><path d="M5 12h14" stroke="currentColor" stroke-width="1.6" opacity=".5"/>',
    "triangle": '<path d="M12 3l9 16H3l9-16z" stroke="currentColor" stroke-width="1.6"/><path d="M12 3v16M7 14h10" stroke="currentColor" stroke-width="1.6" opacity=".5"/>',
    "wave":     '<path d="M3 10c3-6 6 6 9 0s6-6 9 0" stroke="currentColor" stroke-width="1.6" fill="none"/><path d="M3 16c3-6 6 6 9 0s6-6 9 0" stroke="currentColor" stroke-width="1.6" fill="none" opacity=".5"/>',
    "orbit":    '<circle cx="12" cy="12" r="3.5" stroke="currentColor" stroke-width="1.6"/><ellipse cx="12" cy="12" rx="10" ry="4" stroke="currentColor" stroke-width="1.6" opacity=".5"/>',
    "square":   '<rect x="4" y="4" width="16" height="16" rx="3" stroke="currentColor" stroke-width="1.6"/><path d="M4 12h16M12 4v16" stroke="currentColor" stroke-width="1.6" opacity=".5"/>',
}


def icon(key):
    return '<svg viewBox="0 0 24 24">' + ICONS.get(key, ICONS["layers"]) + "</svg>"


def glyph(key):
    return '<svg viewBox="0 0 24 24" fill="none">' + GLYPHS.get(key, GLYPHS["cube"]) + "</svg>"


def code_html(src):
    # Render a terminal/code block: gray for '# comments' and '→ output', accent for the verb.
    out = []
    for line in esc(src).split("\n"):
        if line.startswith("#") or line.startswith("→"):
            out.append('<span class="c">' + line + "</span>")
        else:
            out.append(line)
    return "\n".join(out)


# ---------------------------------------------------------------- CSS
def build_css(pal):
    css = open(os.path.join(MASK_DIR, "templates", "style.css"), "r", encoding="utf-8").read()
    return (css
            .replace("__ACCENT_L__", pal["accent_l"]).replace("__ACCENT_INK_L__", pal["accent_ink_l"])
            .replace("__ACCENT_D__", pal["accent_d"]).replace("__ACCENT_INK_D__", pal["accent_ink_d"]))


# ---------------------------------------------------------------- shared chrome
def head(title, desc, extra=""):
    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        "<title>" + esc(title) + "</title>"
        '<meta name="description" content="' + html.escape(desc, quote=True) + '">'
        '<link rel="icon" type="image/svg+xml" href="/favicon.svg">'
        '<link rel="stylesheet" href="/assets/style.css">' + extra +
        "</head><body>"
    )


def site_header(p, active):
    def a(href, label, key):
        cls = ' class="on"' if key == active else ""
        return '<a' + cls + ' href="' + href + '">' + label + "</a>"
    return (
        '<header class="site"><div class="wrap bar">'
        '<a class="logo" href="/"><span class="g">' + glyph(p["glyph"]) + "</span>" + esc(p["product"]) + "</a>"
        '<nav class="top">' + a("/", "Home", "home") + a("/docs", "Docs", "docs") + a("/license", "License", "license") + "</nav>"
        "</div></header>"
    )


def site_footer(p):
    return (
        '<footer class="site"><div class="wrap"><span class="brand"><span class="g">' + glyph(p["glyph"]) + "</span>" + esc(p["product"]) + "</span>"
        '<nav><a href="/docs">Documentation</a><a href="/license">License</a></nav>'
        '<span class="cr">' + esc(p["footer_line"]) + "</span></div></footer></body></html>"
    )


# ---------------------------------------------------------------- pages
def build_index(p):
    caps = "".join(
        '<div class="cap"><span class="ic">' + icon(c["icon"]) + "</span>"
        "<h3>" + esc(c["title"]) + "</h3><p>" + esc(c["body"]) + "</p></div>"
        for c in p["capabilities"])
    spec = '<span class="sep">·</span>'.join("<span>" + esc(s) + "</span>" for s in p["spec"])
    steps = "".join('<li><span class="k">' + str(i) + "</span><span>" + esc(s) + "</span></li>"
                    for i, s in enumerate(p["how"]["steps"], 1))
    head_html = esc(p["headline"])
    if p.get("headline_em"):
        head_html = head_html.replace(esc(p["headline_em"]), "<em>" + esc(p["headline_em"]) + "</em>")
    body = (
        site_header(p, "home") +
        '<main><div class="wrap"><section class="hero"><div class="hero-txt">'
        '<p class="eyebrow">' + esc(p["category"]) + "</p>"
        "<h1>" + head_html + "</h1>"
        '<p class="lede">' + esc(p["lede"]) + "</p>"
        '<div class="actions"><a class="doclink" href="/docs">Read the documentation <span>&rarr;</span></a>'
        '<span class="install"><span class="p">$</span> ' + esc(p["install"]) + "</span></div>"
        "</div>" + hero_diagram() + "</section></div>"
        '<div class="strip"><div class="wrap"><span><b>' + esc(p["product"]) + "</b> " + esc(p["category"].split()[0]) + "</span>"
        '<span class="sep">·</span>' + spec + "</div></div>"
        '<div class="wrap"><section class="caps" id="capabilities"><h2>Capabilities</h2>'
        '<div class="grid">' + caps + "</div></section>"
        '<section class="how" id="how"><div class="howcard"><div class="txt">'
        "<h2>" + esc(p["how"]["title"]) + "</h2><p>" + esc(p["how"]["intro"]) + "</p>"
        "<ol>" + steps + "</ol></div>"
        '<div class="code">' + code_html(p["how"]["code"]) + "</div></div></section></div></main>"
    )
    return head(p["product"] + " — " + p["category"], p["lede"]) + body + site_footer(p)


def hero_diagram():
    return (
        '<div class="diagram" aria-hidden="true"><svg viewBox="0 0 340 300">'
        '<path class="wire" d="M70 60 C 130 90, 150 110, 170 140"/><path class="wire" d="M270 60 C 210 90, 190 110, 170 140"/>'
        '<path class="wire" d="M55 170 C 100 165, 130 160, 158 158"/>'
        '<path class="flow" d="M70 60 C 130 90, 150 110, 170 140"/><path class="flow" d="M270 60 C 210 90, 190 110, 170 140"/>'
        '<path class="flow" d="M55 170 C 100 165, 130 160, 158 158"/><path class="flow" d="M170 176 L170 226"/>'
        '<rect class="node" x="44" y="40" width="52" height="40" rx="8"/><rect class="node" x="244" y="40" width="52" height="40" rx="8"/>'
        '<rect class="node" x="30" y="152" width="50" height="36" rx="8"/>'
        '<path class="core" d="M170 118 L206 140 V182 L170 204 L134 182 V140 Z"/>'
        '<path class="glyph on-core" d="M170 118 V204 M134 140 L170 162 L206 140" opacity=".8"/>'
        '<path class="node" d="M140 246 v22 c0 4.4 13.4 8 30 8 s30 -3.6 30 -8 v-22" fill="var(--surface-2)"/>'
        '<ellipse class="wire" cx="170" cy="246" rx="30" ry="8"/></svg></div>'
    )


def build_docs(p):
    d = p["docs"]
    port, domain = p["port"], "__DOMAIN__"

    def sub(s):
        return s.replace("@@port@@", port).replace("@@domain@@", domain)

    overview = "".join("<p>" + esc(x) + "</p>" for x in d["overview"])
    cfg_items = "".join("<li><code>" + esc(k) + "</code> — " + esc(v) + "</li>" for k, v in d["config_items"])
    api_rows = "".join("<tr><td><code>" + esc(m) + "</code></td><td>" + esc(t) + "</td></tr>" for m, t in d["api_rows"])
    cli_rows = "".join("<tr><td><code>" + esc(m) + "</code></td><td>" + esc(t) + "</td></tr>" for m, t in d["cli_rows"])
    aside = (
        '<aside><p class="grp">Documentation</p>'
        '<a class="act" href="#overview">Overview</a><a href="#install">Installation</a>'
        '<a href="#quickstart">Quickstart</a><a href="#config">Configuration</a>'
        '<a href="#api">API reference</a><a href="#cli">CLI</a></aside>'
    )
    art = (
        "<article>"
        '<p class="ey">Documentation</p><h1 id="overview">' + esc(p["product"]) + "</h1>"
        '<p class="sub">' + esc(d["sub"]) + "</p>" + overview +
        '<h2 id="install"><span class="hash">#</span>Installation</h2>'
        "<p>" + esc(p["product"]) + " ships as one static binary. Place it on your host and start it:</p>"
        '<pre>' + code_html(sub(d["install_code"])) + "</pre>"
        '<div class="callout">' + esc(sub(d["callout"])) + "</div>"
        '<h2 id="quickstart"><span class="hash">#</span>Quickstart</h2>'
        '<pre>' + code_html(sub(d["quickstart_code"])) + "</pre>"
        '<h2 id="config"><span class="hash">#</span>Configuration</h2>'
        "<p>Configure with flags, environment variables, or a small YAML file. Flags take precedence.</p>"
        '<pre>' + code_html(sub(d["config_yaml"])) + "</pre><ul>" + cfg_items + "</ul>"
        '<h2 id="api"><span class="hash">#</span>API reference</h2><p>' + d["api_intro"] + "</p>"
        '<table><thead><tr><th>Method &amp; path</th><th>Description</th></tr></thead><tbody>' + api_rows + "</tbody></table>"
        '<h2 id="cli"><span class="hash">#</span>CLI</h2>'
        "<p>The <code>" + esc(p["product"].lower()) + "</code> binary is both the server and the client.</p>"
        '<table><thead><tr><th>Command</th><th>Description</th></tr></thead><tbody>' + cli_rows + "</tbody></table>"
        "</article>"
    )
    return (head(p["product"] + " — Documentation", d["sub"]) + site_header(p, "docs") +
            '<div class="wrap doc">' + aside + art + "</div>" + site_footer(p))


MIT = """Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."""


def build_license(p):
    body = (
        site_header(p, "license") +
        '<div class="wrap page"><article class="prose"><p class="ey">License</p>'
        "<h1>MIT License</h1>"
        '<p class="copyright">Copyright &copy; The ' + esc(p["product"]) + " Authors</p>"
        "<pre class=\"license\">" + esc(MIT) + "</pre></article></div>"
    )
    return head(p["product"] + " — License", "MIT License for " + p["product"] + ".") + body + site_footer(p)


def build_404(p):
    body = (
        site_header(p, "") +
        '<div class="wrap page notfound"><div class="nf"><p class="code404">404</p>'
        "<h1>This page could not be found.</h1>"
        '<p class="sub">The page you requested doesn\'t exist or was moved.</p>'
        '<p class="links"><a href="/">Home</a><a href="/docs">Documentation</a></p></div></div>'
    )
    return head("404 — Not found", "Page not found.") + body + site_footer(p)


def build_favicon(p, pal):
    letter = esc(p["product"][:1].lower())
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">'
        '<rect width="32" height="32" rx="7" fill="' + pal["accent_l"] + '"/>'
        '<text x="16" y="22" font-family="ui-monospace,Menlo,Consolas,monospace" font-size="18" '
        'font-weight="700" fill="#fff" text-anchor="middle">' + letter + "</text></svg>"
    )


def build_robots(domain):
    return "User-agent: *\nAllow: /\nSitemap: https://" + domain + "/sitemap.xml\n"


def build_sitemap(domain):
    urls = "".join("<url><loc>https://" + domain + p + "</loc></url>" for p in ("/", "/docs", "/license"))
    return ('<?xml version="1.0" encoding="UTF-8"?>'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + urls + "</urlset>\n")


# ---------------------------------------------------------------- main
def main():
    domain = os.environ.get("MASK_DOMAIN", "").strip().lower()
    dest = os.environ.get("MASK_DEST", "").strip()
    override = os.environ.get("MASK_PRESET", "").strip()
    if not domain or not dest:
        die("MASK_DOMAIN and MASK_DEST are required")

    presets = json.load(open(os.path.join(MASK_DIR, "presets.json"), encoding="utf-8"))
    palettes = json.load(open(os.path.join(MASK_DIR, "palettes.json"), encoding="utf-8"))
    if not presets or not palettes:
        die("empty presets/palettes")

    if override:
        chosen = next((x for x in presets if x["id"] == override), None)
        if chosen is None:
            die("MASK_PRESET '%s' not found" % override)
    else:
        # Peer-aware, deterministic preset selection. MASK_PEERS (comma-separated FQDNs of all
        # decoy domains on THIS box, in a fixed order) lets us hand each domain a DIFFERENT product
        # so two subdomains of one box aren't the same product. With no peers, falls back to the
        # plain per-domain choice. Deterministic given the same peer set → stable across repair.
        peers_env = os.environ.get("MASK_PEERS", "").strip()
        peers = [d.strip().lower() for d in peers_env.split(",") if d.strip()] or [domain]
        if domain not in peers:
            peers = [domain] + peers
        seen = set()
        peers = [d for d in peers if not (d in seen or seen.add(d))]  # dedupe, keep order
        taken, assign = set(), {}
        dedupe = len(peers) <= len(presets)
        for d in peers:
            idx = seed_int(d) % len(presets)
            if dedupe:
                while idx in taken:
                    idx = (idx + 1) % len(presets)
            assign[d] = idx
            taken.add(idx)
        chosen = presets[assign[domain]]
    pal = palettes[seed_int(domain + "|accent") % len(palettes)]

    # substitute the real domain into docs code samples
    def finalize(s):
        return s.replace("__DOMAIN__", domain)

    pages = {
        "index.html": build_index(chosen),
        "docs.html": finalize(build_docs(chosen)),
        "license.html": build_license(chosen),
        "404.html": build_404(chosen),
        "favicon.svg": build_favicon(chosen, pal),
        "robots.txt": build_robots(domain),
        "sitemap.xml": build_sitemap(domain),
        os.path.join("assets", "style.css"): build_css(pal),
    }

    os.makedirs(os.path.join(dest, "assets"), exist_ok=True)
    for rel, content in pages.items():
        path = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True) if os.path.dirname(rel) else None
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
    sys.stdout.write("%s\t%s\n" % (chosen["id"], pal["id"]))


if __name__ == "__main__":
    main()
