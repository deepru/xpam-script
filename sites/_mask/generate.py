#!/usr/bin/env python3
# XPAM Script — deterministic + per-install-UNIQUE decoy mask-site generator.
# Renders a small, self-contained "product landing" site (index/docs/license/404 +
# favicon/robots/sitemap + assets/style.css) into a target web root. Everything about the LOOK is
# derived from the site's own FQDN, so every install is visually unique (defeats a fleet-wide
# template fingerprint) yet fully deterministic (repair/reset reproduce the same site).
# Design + rationale: handoff/MASKING_IDEAS.md section 6 (Phase A).
#
# Inputs (environment):
#   MASK_DOMAIN      full FQDN of the site (e.g. app.example.com)             [required]
#   MASK_DEST        target directory (e.g. /var/www/app.example.com)          [required]
#   MASK_ROLE        primary|sync|root  (informational; all presets are API-shaped)
#   MASK_PRESET      optional preset id override (empty = deterministic auto)
#   MASK_ARCH        optional archetype override (clean|terminal|...; empty = deterministic auto)
#   MASK_PEERS       optional comma-separated FQDNs of all decoy domains on THIS box (anti-collision)
#   MASK_DIR         directory holding presets.json + themes/ (default: this file's dir)
#
# No network, no external assets, SYSTEM FONTS ONLY — everything is inlined or same-origin.
# What varies per FQDN (Phase A): accent palette (continuous hue), CSS class names (mangled),
# hero SVG diagram + favicon shape (procedural), product name (generated). The URL surface
# (file names + routes /docs //license //health //v1 + panel path) is NEVER randomized — health
# checks and the nginx config depend on it.

import hashlib, html, json, math, os, random, re, sys

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


# ---------------------------------------------------------------- per-install uniqueness

# Every CSS class the stylesheet + builders use. The mangle map renames these consistently in
# BOTH the CSS and the rendered HTML. A class NOT listed here is simply left un-mangled on both
# sides (still consistent) — so completeness only affects how much is randomized, never correctness.
CLASS_SET = [
    "wrap", "site", "bar", "logo", "g", "top", "on", "hero", "hero-txt", "eyebrow", "lede",
    "actions", "doclink", "install", "p", "diagram", "node", "core", "glyph", "on-core", "flow",
    "wire", "strip", "sep", "caps", "grid", "cap", "ic", "how", "howcard", "txt", "k", "code", "c",
    "doc", "aside", "ey", "sub", "hash", "callout", "page", "prose", "copyright", "license",
    "notfound", "nf", "code404", "links", "brand", "cr", "act", "grp",
    # structural variants (layout profiles)
    "h-split", "h-mirror", "h-center", "h-bigtype", "h-stacked", "visual", "wide",
    "termwin", "tw-bar", "tw-dot", "tw-body", "uicard", "uc-head", "uc-row", "uc-tag", "uc-spark",
    "meta", "metarow", "caplist", "capnum", "spectable", "cta", "navmin", "navcta",
]


def build_class_map(domain):
    """Deterministic per-FQDN class-name map. Short minified-looking tokens (letter-led)."""
    rnd = random.Random(seed_int(domain + "|cls"))
    alph = "abcdefghijklmnopqrstuvwxyz"
    alnum = alph + "0123456789"
    used, m = set(), {}
    for name in CLASS_SET:
        while True:
            tok = rnd.choice(alph) + "".join(rnd.choice(alnum) for _ in range(rnd.randint(1, 3)))
            if tok not in used:
                break
        used.add(tok)
        m[name] = tok
    return m


def mangle_css(css, cmap):
    # Rename `.class` selectors only. The pattern requires a LETTER after the dot, so numeric
    # values like `-.02em`, `1.6`, `.9rem` are never touched; `[\w-]*` captures the whole
    # identifier so `.code` maps `code` (not `c`).
    return re.sub(r"\.([A-Za-z][\w-]*)",
                  lambda mm: "." + cmap.get(mm.group(1), mm.group(1)), css)


def mangle_html(page, cmap):
    # Rename class attribute values. Only our own class="..." attributes exist in the output.
    def repl(mm):
        return 'class="' + " ".join(cmap.get(x, x) for x in mm.group(1).split()) + '"'
    return re.sub(r'class="([^"]*)"', repl, page)


def hsl_to_hex(h, s, l):
    h = h % 360.0
    c = (1 - abs(2 * l - 1)) * s
    x = c * (1 - abs((h / 60.0) % 2 - 1))
    mm = l - c / 2
    r, g, b = [(c, x, 0), (x, c, 0), (0, c, x), (0, x, c), (x, 0, c), (c, 0, x)][int(h // 60) % 6]
    return "#%02x%02x%02x" % (round((r + mm) * 255), round((g + mm) * 255), round((b + mm) * 255))


# Curated accent hue bands — the ranges that read as a designed brand accent. Deliberately skips
# the muddy yellow/olive/yellow-green (45–125), sickly cyan (188–205) and garish magenta (292–322)
# zones, so a random hue never lands on an "off" colour.
_HUE_BANDS = [
    (18, 40),    # amber / warm orange
    (128, 168),  # green → emerald
    (168, 188),  # teal
    (205, 255),  # blue → indigo
    (255, 292),  # indigo → violet
    (325, 358),  # rose / crimson
]


# Per-archetype colour character: which hue bands it may use, and how saturated. Without this every
# archetype on the same domain got the SAME accent, which made them look like one site recoloured.
# (bands, sat_light_range, sat_dark_range)
_ARCH_COLOR = {
    "clean":     (_HUE_BANDS,                        (0.52, 0.68), (0.66, 0.82)),
    "terminal":  ([(168, 188), (205, 255), (128, 168)], (0.55, 0.70), (0.78, 0.92)),
    "editorial": ([(18, 40), (325, 358), (128, 168)], (0.28, 0.42), (0.34, 0.48)),   # muted
    "financial": ([(205, 250)],                      (0.55, 0.70), (0.62, 0.76)),   # fintech blue
    "atlas":     ([(18, 40), (128, 168), (205, 250)], (0.40, 0.55), (0.48, 0.62)),   # calm warm/earthy
    "soft":      ([(255, 292), (205, 255), (325, 358)], (0.42, 0.56), (0.55, 0.70)),  # pastel
    "midnight":  ([(18, 44), (325, 358)],            (0.34, 0.48), (0.40, 0.56)),   # muted warm
    "console":   ([(128, 168), (168, 188), (40, 56)], (0.60, 0.78), (0.72, 0.90)),  # phosphor
    "slate":     ([(196, 232)],                      (0.20, 0.34), (0.26, 0.40)),   # desaturated cool
    "aurora":    ([(255, 300), (205, 255)],          (0.62, 0.80), (0.76, 0.94)),   # vivid
}


def build_palette(domain, arch):
    """Accent from the FQDN **and the archetype** → the 4 accent tokens the stylesheet expects.
    Each archetype has its own hue bands + saturation character, so two archetypes never share a
    palette even on the same domain, and each still varies per install."""
    rnd = random.Random(seed_int(domain + "|css|" + arch))
    bands, sl, sd = _ARCH_COLOR.get(arch, (_HUE_BANDS, (0.52, 0.68), (0.66, 0.82)))
    lo, hi = rnd.choice(bands)
    hue = rnd.uniform(lo, hi)
    s_l = rnd.uniform(*sl)
    s_d = rnd.uniform(*sd)
    return {
        "id": "h%d" % round(hue),
        "accent_l":     hsl_to_hex(hue, s_l, rnd.uniform(0.38, 0.45)),
        "accent_ink_l": hsl_to_hex(hue, min(s_l + 0.05, 0.9), rnd.uniform(0.29, 0.35)),
        "accent_d":     hsl_to_hex(hue, s_d, rnd.uniform(0.62, 0.70)),
        "accent_ink_d": hsl_to_hex(hue, max(s_d - 0.12, 0.3), rnd.uniform(0.78, 0.86)),
    }


# --- layout profiles: each archetype gets a DIFFERENT page skeleton, not just a different skin ---
# hero:  split | mirror | center | bigtype | stacked
# vis:   diagram | terminal | uicard | none
# caps:  grid3 | grid2 | list | table
# how:   split | stacked | none
# nav:   full | min | cta
# order: sequence of sections after the hero
LAYOUT = {
    "clean":     {"hero": "split",   "vis": "diagram",  "caps": "grid3", "how": "split",   "nav": "full", "order": ["strip", "caps", "how"]},
    "terminal":  {"hero": "stacked", "vis": "terminal", "caps": "grid3", "how": "split",   "nav": "full", "order": ["caps", "strip", "how"]},
    "editorial": {"hero": "bigtype", "vis": "none",     "caps": "list",  "how": "stacked", "nav": "min",  "order": ["caps", "how", "strip"]},
    "financial": {"hero": "mirror",  "vis": "uicard",   "caps": "grid2", "how": "split",   "nav": "cta",  "order": ["caps", "strip", "how"]},
    "atlas":     {"hero": "center",  "vis": "terminal", "caps": "grid2", "how": "stacked", "nav": "min",  "order": ["strip", "caps", "how"]},
    "soft":      {"hero": "center",  "vis": "uicard",   "caps": "grid3", "how": "stacked", "nav": "full", "order": ["caps", "how"]},
    "midnight":  {"hero": "center",  "vis": "uicard",   "caps": "list",  "how": "split",   "nav": "min",  "order": ["caps", "strip", "how"]},
    "console":   {"hero": "stacked", "vis": "terminal", "caps": "list",  "how": "stacked", "nav": "full", "order": ["strip", "caps", "how"]},
    "slate":     {"hero": "split",   "vis": "uicard",   "caps": "table", "how": "split",   "nav": "cta",  "order": ["strip", "caps", "how"]},
    "aurora":    {"hero": "center",  "vis": "diagram",  "caps": "grid3", "how": "split",   "nav": "cta",  "order": ["caps", "strip", "how"]},
}


# --- product name generator (coined, fictional, pronounceable) ---
_ONSET = ["b", "c", "d", "f", "g", "h", "k", "l", "m", "n", "p", "r", "s", "t", "v", "z",
          "br", "cr", "dr", "fr", "gr", "pr", "tr", "st", "sl", "sn", "cl", "fl", "gl", "kr",
          "th", "sk", "sp", "vr", "ny", "ov", "el"]
_NUCLEUS = ["a", "e", "i", "o", "u", "ar", "er", "or", "en", "in", "on", "el", "al", "yn", "ur"]
_CODA = ["n", "r", "l", "x", "th", "nd", "rk", "st", "sk", "ll", "rn", "m", "ss", "ft", "lt", "ve", "s"]
_NAME_BLOCK = {"google", "apple", "yandex", "amazon", "cloudflare", "nginx", "microsoft", "oracle",
               "docker", "github", "telegram", "android", "windows", "chrome", "firefox", "xray",
               "reality", "vision", "meta", "adobe", "netflix", "stripe", "vercel", "linear"}


def gen_name(domain):
    rnd = random.Random(seed_int(domain + "|name"))
    for _ in range(64):
        syl = rnd.choice(_ONSET) + rnd.choice(_NUCLEUS)
        core = rnd.choice(_ONSET) + rnd.choice(_NUCLEUS) + rnd.choice(_CODA)
        word = syl + core
        if 5 <= len(word) <= 9 and word.lower() not in _NAME_BLOCK:
            return word[:1].upper() + word[1:]
    return "Vantor"


# ---------------------------------------------------------------- archetypes / CSS
# Each archetype is a whole visual language (its own themes/<id>.css, single committed theme).
# The seed picks one; all share the same class vocabulary + HTML skeleton, so Phase A's mangling
# and the builders are unchanged. A theme file references whichever accent tokens suit its ground.
ARCHES = ["clean", "terminal", "editorial", "financial", "atlas",
          "soft", "midnight", "console", "slate", "aurora"]


def assign_index(domain, peers, n, salt=""):
    """Deterministic, peer-aware index in [0,n). Every decoy domain on THIS box gets a DIFFERENT
    index while peers <= n, so 5-6 domains on one server never share an archetype/preset.
    Stable for a given (peer set, domain) — repair/reset reproduce the same choice."""
    taken, assign = set(), {}
    dedupe = len(peers) <= n
    for d in peers:
        idx = seed_int(d + salt) % n
        if dedupe:
            while idx in taken:
                idx = (idx + 1) % n
        assign[d] = idx
        taken.add(idx)
    return assign[domain]


def build_css(pal, arch):
    path = os.path.join(MASK_DIR, "themes", arch + ".css")
    if not os.path.isfile(path):
        path = os.path.join(MASK_DIR, "themes", "clean.css")
    theme = open(path, "r", encoding="utf-8").read()
    # Shared structural primitives (hero layouts, visuals, caps blocks, nav variants), written
    # against the theme's own tokens. They come FIRST so a theme can always override their
    # cosmetics; the hero grid rules still win over a theme's plain `.hero{}` on specificity.
    layout = os.path.join(MASK_DIR, "themes", "_layout.css")
    base = open(layout, "r", encoding="utf-8").read() + "\n" if os.path.isfile(layout) else ""
    css = base + theme
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


_NAV = "full"  # set per archetype in main(); docs/license/404 inherit it


def site_header(p, active, nav=None):
    nav = nav or _NAV

    def a(href, label, key):
        cls = ' class="on"' if key == active else ""
        return '<a' + cls + ' href="' + href + '">' + label + "</a>"

    if nav == "min":
        links = '<nav class="top navmin">' + a("/docs", "Docs", "docs") + a("/license", "License", "license") + "</nav>"
    elif nav == "cta":
        links = ('<nav class="top navcta">' + a("/", "Home", "home") + a("/docs", "Docs", "docs")
                 + '<a class="cta" href="/docs">Get started</a></nav>')
    else:
        links = ('<nav class="top">' + a("/", "Home", "home") + a("/docs", "Docs", "docs")
                 + a("/license", "License", "license") + "</nav>")
    return (
        '<header class="site"><div class="wrap bar">'
        '<a class="logo" href="/"><span class="g">' + glyph(p["glyph"]) + "</span>" + esc(p["product"]) + "</a>"
        + links + "</div></header>"
    )


def site_footer(p):
    return (
        '<footer class="site"><div class="wrap"><span class="brand"><span class="g">' + glyph(p["glyph"]) + "</span>" + esc(p["product"]) + "</span>"
        '<nav><a href="/docs">Documentation</a><a href="/license">License</a></nav>'
        '<span class="cr">' + esc(p["footer_line"]) + "</span></div></footer></body></html>"
    )


# ---------------------------------------------------------------- pages
def _headline_html(p):
    h = esc(p["headline"])
    if p.get("headline_em"):
        h = h.replace(esc(p["headline_em"]), "<em>" + esc(p["headline_em"]) + "</em>")
    return h


def _hero_text(p):
    return (
        '<p class="eyebrow">' + esc(p["category"]) + "</p>"
        "<h1>" + _headline_html(p) + "</h1>"
        '<p class="lede">' + esc(p["lede"]) + "</p>"
        '<div class="actions"><a class="doclink" href="/docs">Read the documentation <span>&rarr;</span></a>'
        '<span class="install"><span class="p">$</span> ' + esc(p["install"]) + "</span></div>"
    )


def _metarow(p):
    return '<div class="metarow">' + "".join("<span>" + esc(s) + "</span>" for s in p["spec"]) + "</div>"


# ---- hero visuals -------------------------------------------------------------
def visual_terminal(p):
    title = esc(p["product"].lower()) + " — shell"
    return (
        '<div class="visual termwin"><div class="tw-bar">'
        '<span class="tw-dot"></span><span class="tw-dot"></span><span class="tw-dot"></span>'
        "<span>" + title + "</span></div>"
        '<pre class="tw-body">' + code_html(p["how"]["code"]) + "</pre></div>"
    )


def visual_uicard(p, rng):
    rows = "".join(
        '<div class="uc-row"><code>' + esc(m) + "</code><span>" + esc(t) + "</span></div>"
        for m, t in p["docs"]["api_rows"][:4])
    pts = " ".join("%d,%d" % (i * 26, 34 - (h % 26)) for i, h in
                   enumerate(rng.sample(range(4, 30), 10)))
    spark = ('<svg class="uc-spark" viewBox="0 0 234 40" preserveAspectRatio="none">'
             '<polyline points="' + pts + '" fill="none" stroke="currentColor" stroke-width="2" '
             'stroke-linejoin="round"/></svg>')
    return (
        '<div class="visual uicard"><div class="uc-head"><b>' + esc(p["product"]) + " API</b>"
        '<span class="uc-tag">v1</span></div>' + spark + rows + "</div>"
    )


def hero_visual(kind, p, rng):
    if kind == "diagram":
        return hero_diagram(rng)
    if kind == "terminal":
        return visual_terminal(p)
    if kind == "uicard":
        return visual_uicard(p, rng)
    return ""


# ---- capability blocks --------------------------------------------------------
def caps_block(kind, p):
    head_h2 = "<h2>Capabilities</h2>"
    if kind == "list":
        items = "".join(
            '<div class="cap"><span class="capnum">' + "%02d" % i + "</span><div>"
            "<h3>" + esc(c["title"]) + "</h3><p>" + esc(c["body"]) + "</p></div></div>"
            for i, c in enumerate(p["capabilities"], 1))
        inner = '<div class="caplist">' + items + "</div>"
    elif kind == "table":
        rows = "".join("<tr><td>" + esc(c["title"]) + "</td><td>" + esc(c["body"]) + "</td></tr>"
                       for c in p["capabilities"])
        inner = '<table class="spectable"><tbody>' + rows + "</tbody></table>"
    else:  # grid3 / grid2 — same markup, the theme decides the column count
        inner = '<div class="grid">' + "".join(
            '<div class="cap"><span class="ic">' + icon(c["icon"]) + "</span>"
            "<h3>" + esc(c["title"]) + "</h3><p>" + esc(c["body"]) + "</p></div>"
            for c in p["capabilities"]) + "</div>"
    return '<section class="caps" id="capabilities">' + head_h2 + inner + "</section>"


def how_block(kind, p):
    if kind == "none":
        return ""
    steps = "".join('<li><span class="k">' + str(i) + "</span><span>" + esc(s) + "</span></li>"
                    for i, s in enumerate(p["how"]["steps"], 1))
    txt = ("<h2>" + esc(p["how"]["title"]) + "</h2><p>" + esc(p["how"]["intro"]) + "</p>"
           "<ol>" + steps + "</ol>")
    code = '<div class="code">' + code_html(p["how"]["code"]) + "</div>"
    if kind == "stacked":
        return ('<section class="how" id="how"><div class="howcard wide">'
                '<div class="txt">' + txt + "</div>" + code + "</div></section>")
    return ('<section class="how" id="how"><div class="howcard"><div class="txt">' + txt
            + "</div>" + code + "</div></section>")


def strip_block(p):
    spec = '<span class="sep">·</span>'.join("<span>" + esc(s) + "</span>" for s in p["spec"])
    return ('<div class="strip"><div class="wrap"><span><b>' + esc(p["product"]) + "</b> "
            + esc(p["category"].split()[0]) + "</span>"
            '<span class="sep">·</span>' + spec + "</div></div>")


def build_index(p, rng, arch):
    prof = LAYOUT.get(arch, LAYOUT["clean"])
    vis = hero_visual(prof["vis"], p, rng)
    kind = prof["hero"]

    if kind == "mirror":
        hero = ('<div class="wrap"><section class="hero h-mirror">' + vis
                + '<div class="hero-txt">' + _hero_text(p) + "</div></section></div>")
    elif kind == "center":
        hero = ('<div class="wrap"><section class="hero h-center"><div class="hero-txt">'
                + _hero_text(p) + "</div></section>"
                + ('<div class="wide">' + vis + "</div>" if vis else "") + "</div>")
    elif kind == "bigtype":
        hero = ('<div class="wrap"><section class="hero h-bigtype"><div class="hero-txt">'
                '<p class="eyebrow">' + esc(p["category"]) + "</p><h1>" + _headline_html(p) + "</h1></div>"
                '<div class="meta"><p class="lede">' + esc(p["lede"]) + "</p>"
                '<div class="actions"><a class="doclink" href="/docs">Read the documentation <span>&rarr;</span></a>'
                '<span class="install"><span class="p">$</span> ' + esc(p["install"]) + "</span></div>"
                + _metarow(p) + "</div></section></div>")
    elif kind == "stacked":
        hero = ('<div class="wrap"><section class="hero h-stacked"><div class="hero-txt">'
                + _hero_text(p) + "</div></section>"
                + ('<div class="wide">' + vis + "</div>" if vis else "") + "</div>")
    else:  # split
        hero = ('<div class="wrap"><section class="hero h-split"><div class="hero-txt">'
                + _hero_text(p) + "</div>" + vis + "</section></div>")

    parts = []
    for sec in prof["order"]:
        if sec == "strip":
            parts.append(strip_block(p))
        elif sec == "caps":
            parts.append('<div class="wrap">' + caps_block(prof["caps"], p) + "</div>")
        elif sec == "how":
            hb = how_block(prof["how"], p)
            if hb:
                parts.append('<div class="wrap">' + hb + "</div>")

    body = site_header(p, "home", prof["nav"]) + "<main>" + hero + "".join(parts) + "</main>"
    return head(p["product"] + " — " + p["category"], p["lede"]) + body + site_footer(p)


def hero_diagram(rng):
    # Procedural: node positions + bezier control points jitter per install, and the number of
    # top inputs (2 or 3) varies, so the SVG path strings differ from every other install.
    def j(base, amt):
        return base + rng.randint(-amt, amt)

    cx, cy = j(170, 8), j(150, 6)
    r = j(37, 3)
    hexpts = []
    for k in range(6):
        a = math.radians(60 * k - 90)
        hexpts.append((cx + r * math.cos(a), cy + r * 0.92 * math.sin(a)))
    core = "M" + " L".join("%.0f %.0f" % (x, y) for x, y in hexpts) + " Z"
    gl = ("M%.0f %.0f V%.0f M%.0f %.0f L%.0f %.0f"
          % (cx, cy - r * 0.9, cy + r * 0.9, cx - r * 0.72, cy - r * 0.2, cx, cy + r * 0.15))

    n_in = rng.choice([2, 3])
    if n_in == 2:
        xs = [j(62, 12), j(278, 12)]
    else:
        xs = [j(52, 8), j(170, 12), j(288, 8)]

    def curve(x1, y1, x2, y2, bow=0):
        my = (y1 + y2) / 2
        return ("M%.0f %.0f C %.0f %.0f, %.0f %.0f, %.0f %.0f"
                % (x1, y1, x1 + bow, my, x2 - bow, my, x2, y2))

    wires, flows, nodes = [], [], []
    for x in xs:
        y = j(50, 6)
        nodes.append('<rect class="node" x="%d" y="%d" width="52" height="36" rx="8"/>' % (x - 26, y - 18))
        d = curve(x, y + 18, cx + (x - cx) * 0.12, cy - r)
        wires.append('<path class="wire" d="%s"/>' % d)
        flows.append('<path class="flow" d="%s"/>' % d)
    # side input
    sx, sy = j(44, 6), j(168, 8)
    nodes.append('<rect class="node" x="%d" y="%d" width="50" height="34" rx="8"/>' % (sx - 25, sy - 17))
    ds = curve(sx + 25, sy, cx - r, cy + 4, bow=18)
    wires.append('<path class="wire" d="%s"/>' % ds)
    flows.append('<path class="flow" d="%s"/>' % ds)
    # output down to a cylinder
    by = j(250, 6)
    db = "M%.0f %.0f L%.0f %.0f" % (cx, cy + r, cx, by - 24)
    wires.append('<path class="wire" d="%s"/>' % db)
    flows.append('<path class="flow" d="%s"/>' % db)
    cyl = ('<path class="node" d="M%.0f %.0f v22 c0 4.4 13.4 8 30 8 s30 -3.6 30 -8 v-22" fill="var(--surface-2)"/>'
           '<ellipse class="wire" cx="%.0f" cy="%.0f" rx="30" ry="8"/>' % (cx - 30, by, cx, by))

    return (
        '<div class="diagram" aria-hidden="true"><svg viewBox="0 0 340 300">'
        + "".join(wires) + "".join(flows)
        + "".join(nodes)
        + '<path class="core" d="%s"/>' % core
        + '<path class="glyph on-core" d="%s" opacity=".8"/>' % gl
        + cyl + "</svg></div>"
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


def build_favicon(p, pal, rng):
    letter = esc(p["product"][:1].lower())
    accent = pal["accent_l"]
    shape = rng.choice(["rrect", "rrect", "circle", "hex"])
    if shape == "circle":
        bg = '<circle cx="16" cy="16" r="15" fill="%s"/>' % accent
    elif shape == "hex":
        bg = '<path d="M16 1.5l12.6 7.3v14.4L16 30.5 3.4 23.2V8.8z" fill="%s"/>' % accent
    else:
        bg = '<rect width="32" height="32" rx="%d" fill="%s"/>' % (rng.choice([6, 7, 8, 9]), accent)
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">' + bg +
        '<text x="16" y="22" font-family="ui-monospace,Menlo,Consolas,monospace" font-size="18" '
        'font-weight="700" fill="#fff" text-anchor="middle">' + letter + "</text></svg>"
    )


def build_robots(domain):
    return "User-agent: *\nAllow: /\nSitemap: https://" + domain + "/sitemap.xml\n"


def build_sitemap(domain):
    urls = "".join("<url><loc>https://" + domain + p + "</loc></url>" for p in ("/", "/docs", "/license"))
    return ('<?xml version="1.0" encoding="UTF-8"?>'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + urls + "</urlset>\n")


def apply_identity(preset, name, glyph_key):
    """Swap the preset's product name (deeply embedded: CLI, prose, footer, docs) for the
    generated one, and set the seed-picked glyph. Done as a whole-blob token replace so every
    reference stays consistent."""
    old_cap, old_low = preset["product"], preset["id"]
    blob = json.dumps(preset, ensure_ascii=False)
    # Word-BOUNDED replacement on purpose. A naive substring replace would corrupt prose the moment a
    # preset id happens to sit inside another word — e.g. an "ember" preset would mangle "September",
    # "slate" would mangle "translate", "pulse" would mangle "impulse". Today no preset trips that,
    # but adding one later must not silently break the copy.
    blob = re.sub(r"\b%s\b" % re.escape(old_cap), name, blob)
    blob = re.sub(r"\b%s\b" % re.escape(old_low), name.lower(), blob)
    out = json.loads(blob)
    out["glyph"] = glyph_key
    return out


# ---------------------------------------------------------------- main
def main():
    domain = os.environ.get("MASK_DOMAIN", "").strip().lower()
    dest = os.environ.get("MASK_DEST", "").strip()
    override = os.environ.get("MASK_PRESET", "").strip()
    if not domain or not dest:
        die("MASK_DOMAIN and MASK_DEST are required")

    presets = json.load(open(os.path.join(MASK_DIR, "presets.json"), encoding="utf-8"))
    if not presets:
        die("empty presets")

    # MASK_PEERS = all decoy FQDNs on THIS box, fixed order (primary, sync, root, ...). Used to give
    # each domain of one box a DIFFERENT archetype AND a different content skeleton.
    peers_env = os.environ.get("MASK_PEERS", "").strip()
    peers = [d.strip().lower() for d in peers_env.split(",") if d.strip()] or [domain]
    if domain not in peers:
        peers = [domain] + peers
    seen = set()
    peers = [d for d in peers if not (d in seen or seen.add(d))]  # dedupe, keep order

    if override:
        chosen = next((x for x in presets if x["id"] == override), None)
        if chosen is None:
            die("MASK_PRESET '%s' not found" % override)
    else:
        chosen = presets[assign_index(domain, peers, len(presets))]

    # --- per-install identity: archetype + generated name + glyph + palette + class map
    arch = os.environ.get("MASK_ARCH", "").strip() or ARCHES[assign_index(domain, peers, len(ARCHES), "|arch")]
    if arch not in ARCHES:
        die("MASK_ARCH '%s' not found (have: %s)" % (arch, ", ".join(ARCHES)))
    global _NAV
    _NAV = LAYOUT.get(arch, LAYOUT["clean"])["nav"]
    rng_svg = random.Random(seed_int(domain + "|svg|" + arch))
    name = gen_name(domain)
    glyph_key = rng_svg.choice(list(GLYPHS.keys()))
    chosen = apply_identity(chosen, name, glyph_key)
    pal = build_palette(domain, arch)
    cmap = build_class_map(domain)

    def finalize(s):
        return s.replace("__DOMAIN__", domain)

    html_pages = {
        "index.html": build_index(chosen, rng_svg, arch),
        "docs.html": finalize(build_docs(chosen)),
        "license.html": build_license(chosen),
        "404.html": build_404(chosen),
    }
    pages = {rel: mangle_html(page, cmap) for rel, page in html_pages.items()}
    pages["favicon.svg"] = build_favicon(chosen, pal, rng_svg)
    pages["robots.txt"] = build_robots(domain)
    pages["sitemap.xml"] = build_sitemap(domain)
    pages[os.path.join("assets", "style.css")] = mangle_css(build_css(pal, arch), cmap)

    os.makedirs(os.path.join(dest, "assets"), exist_ok=True)
    for rel, content in pages.items():
        path = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True) if os.path.dirname(rel) else None
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
    sys.stdout.write("%s\t%s\t%s\t%s\n" % (arch, chosen["id"], pal["id"], name))


if __name__ == "__main__":
    main()
