#!/usr/bin/env python3
"""Renders docs/legal/*.md into standalone HTML pages for hosting.

    python3 scripts/build-legal-pages.py

The markdown is the source of truth and lives in the repo, so the policy is
reviewable as a diff. Output goes to build/legal/ for upload to the web host.

Deliberately a tiny hand-rolled converter rather than a dependency: the input is
our own text using a small, known subset of markdown, and a policy page is not
the place to pull in an unpinned parser.
"""

import html
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "docs", "legal")
OUT = os.path.join(ROOT, "build", "legal")

STYLE = """
:root {
  color-scheme: light dark;
  --bg: #ffffff; --fg: #1b2420; --muted: #5c6f66;
  --rule: #dfe8e3; --link: #0d6b4f;
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #0d1512; --fg: #e6efea; --muted: #9fb5ab;
          --rule: #223029; --link: #6ee0b0; }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 17px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  -webkit-text-size-adjust: 100%;
}
main { max-width: 44rem; margin: 0 auto; padding: 3rem 1.25rem 5rem; }
h1 { font-size: 1.9rem; line-height: 1.2; margin: 0 0 .5rem; letter-spacing: -0.02em; }
h2 { font-size: 1.2rem; margin: 2.5rem 0 .75rem; padding-top: 1.25rem;
     border-top: 1px solid var(--rule); letter-spacing: -0.01em; }
p, li { margin: 0 0 1rem; }
ul { padding-left: 1.25rem; }
li { margin-bottom: .4rem; }
a { color: var(--link); }
strong { font-weight: 650; }
.meta { color: var(--muted); font-size: .95rem; margin-bottom: 2rem; }
.meta p { margin: 0; }
footer { margin-top: 3rem; padding-top: 1.25rem; border-top: 1px solid var(--rule);
         color: var(--muted); font-size: .9rem; }
"""


def inline(text):
    """Escape, then re-apply the inline markup we actually use."""
    text = html.escape(text, quote=False)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)",
                  r'<a href="\2" rel="noopener">\1</a>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    return text


def render(md):
    out, in_list, meta_done = [], False, False

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for raw in md.split("\n"):
        line = raw.rstrip()
        if not line:
            close_list()
            continue
        if line.startswith("# "):
            close_list()
            out.append(f"<h1>{inline(line[2:])}</h1>")
        elif line.startswith("## "):
            close_list()
            # The effective/updated block sits between the h1 and the first h2.
            if not meta_done:
                meta_done = True
            out.append(f"<h2>{inline(line[3:])}</h2>")
        elif line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(line[2:])}</li>")
        else:
            close_list()
            cls = ' class="meta"' if not meta_done and line.startswith("**") else ""
            out.append(f"<p{cls}>{inline(line)}</p>")
    close_list()
    return "\n".join(out)


def page(title, body):
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<!-- Unlisted: reachable by URL for Plaid and app-store review, but kept out of
     search results. Note there is deliberately no robots.txt Disallow for this
     path — a disallowed crawler never reads the page, and so never sees this
     noindex, which is the opposite of what we want. -->
<meta name="robots" content="noindex, nofollow">
<title>{html.escape(title)}</title>
<style>{STYLE}</style>
</head>
<body>
<main>
{body}
<footer>Budget is a private, self-hosted app for one household. It is not offered as a commercial service.</footer>
</main>
</body>
</html>
"""


os.makedirs(OUT, exist_ok=True)
count = 0
for name in sorted(os.listdir(SRC)):
    if not name.endswith(".md"):
        continue
    with open(os.path.join(SRC, name)) as f:
        md = f.read()
    title = next((l[2:].strip() for l in md.split("\n") if l.startswith("# ")), "Budget")
    dest = os.path.join(OUT, name[:-3] + ".html")
    with open(dest, "w") as f:
        f.write(page(title, render(md)))
    print("wrote", os.path.relpath(dest, ROOT))
    count += 1

if count == 0:
    print("no markdown found in docs/legal", file=sys.stderr)
    sys.exit(1)
