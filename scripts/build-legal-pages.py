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
# Both the consumer-facing policy and the internal ones: the same rendering
# serves the hosted page and the PDFs attached to compliance reviews.
SRC_DIRS = [("legal", os.path.join(ROOT, "docs", "legal")),
            ("security", os.path.join(ROOT, "docs", "security"))]
OUT_ROOT = os.path.join(ROOT, "build")

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
ul, ol { padding-left: 1.35rem; }
li { margin-bottom: .4rem; }
a { color: var(--link); }
strong { font-weight: 650; }
.meta { color: var(--muted); font-size: .95rem; margin-bottom: 2rem; }
.meta p { margin: 0; }
footer { margin-top: 3rem; padding-top: 1.25rem; border-top: 1px solid var(--rule);
         color: var(--muted); font-size: .9rem; }
table { border-collapse: collapse; width: 100%; margin: 0 0 1.25rem; font-size: .95rem; }
th, td { text-align: left; padding: .5rem .6rem; border-bottom: 1px solid var(--rule);
         vertical-align: top; }
th { font-weight: 650; }
.wrap { overflow-x: auto; }

@media print {
  /* Force the light palette: a dark page wastes toner and reads badly on
     paper, and reviewers print these. */
  :root { --bg: #fff; --fg: #000; --muted: #444; --rule: #bbb; --link: #000; }
  body { font-size: 10.5pt; }
  main { max-width: none; padding: 0; }
  h2 { page-break-after: avoid; }
  tr, li, table { page-break-inside: avoid; }
  footer { page-break-before: avoid; }
  a { text-decoration: none; }
}
@page { margin: 18mm 16mm; }
"""


def inline(text):
    """Escape, then re-apply the inline markup we actually use."""
    text = html.escape(text, quote=False)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)",
                  r'<a href="\2" rel="noopener">\1</a>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    return text


def is_divider(line):
    """The |---|---| row under a markdown table header."""
    return bool(re.fullmatch(r"\|[\s:|-]+\|", line.strip()))


def cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def render(md):
    """Markdown subset -> HTML.

    The source is hard-wrapped at 80 columns for reviewable diffs, so
    consecutive non-blank lines are one paragraph and must be joined. Emitting
    a <p> per source line — as an earlier version did — turns every document
    into a column of sentence fragments.
    """
    out, meta_done = [], False
    lines = md.split("\n")
    i = 0
    para: list[str] = []
    list_tag = None   # "ul" | "ol" | None
    item: list[str] = []

    def flush_para():
        nonlocal para, meta_done
        if not para:
            return
        # The owner/effective-date block sits between the h1 and the first h2.
        # Those are discrete fields, one per line, so they keep their line
        # breaks instead of being reflowed into one run-on sentence the way an
        # ordinary paragraph is.
        is_meta = not meta_done and para[0].startswith("**")
        text = ("<br>" if is_meta else " ").join(
            inline(line) for line in para)
        cls = ' class="meta"' if is_meta else ""
        out.append(f"<p{cls}>{text}</p>")
        para = []

    def flush_item():
        nonlocal item
        if item:
            out.append(f"<li>{inline(' '.join(item))}</li>")
            item = []

    def close_list():
        nonlocal list_tag
        flush_item()
        if list_tag:
            out.append(f"</{list_tag}>")
            list_tag = None

    def open_list(tag):
        nonlocal list_tag
        if list_tag != tag:
            close_list()
            out.append(f"<{tag}>")
            list_tag = tag

    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip()

        # Table: header row, divider, then body rows.
        if line.startswith("|") and i + 1 < len(lines) and is_divider(lines[i + 1]):
            flush_para(); close_list()
            out.append('<div class="wrap"><table><thead><tr>')
            out += [f"<th>{inline(c)}</th>" for c in cells(line)]
            out.append("</tr></thead><tbody>")
            i += 2
            while i < len(lines) and lines[i].strip().startswith("|"):
                out.append("<tr>")
                out += [f"<td>{inline(c)}</td>" for c in cells(lines[i])]
                out.append("</tr>")
                i += 1
            out.append("</tbody></table></div>")
            continue

        i += 1

        if not line.strip():
            flush_para(); close_list()
            continue

        if line.startswith("# "):
            flush_para(); close_list()
            out.append(f"<h1>{inline(line[2:])}</h1>")
            continue

        if line.startswith("## "):
            flush_para(); close_list()
            meta_done = True
            out.append(f"<h2>{inline(line[3:])}</h2>")
            continue

        bullet = re.match(r"^- +(.*)$", line)
        numbered = re.match(r"^\d+\. +(.*)$", line)
        if bullet or numbered:
            flush_para()
            flush_item()
            open_list("ul" if bullet else "ol")
            item = [(bullet or numbered).group(1)]
            continue

        # A continuation line: indented under a list item, or more of a
        # paragraph. Either way it joins what came before rather than
        # starting something new.
        if list_tag and raw.startswith(("  ", "\t")):
            item.append(line.strip())
            continue

        if list_tag:
            close_list()
        para.append(line.strip())

    flush_para()
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


CHROME = ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")


def to_pdf(html_path):
    """Headless Chrome, because it is already on the machine and renders the
    same CSS the page uses — no second rendering engine to keep in agreement."""
    import subprocess
    pdf_path = html_path[:-5] + ".pdf"
    proc = subprocess.run(
        [CHROME, "--headless", "--disable-gpu", "--no-sandbox",
         "--no-pdf-header-footer", f"--print-to-pdf={pdf_path}",
         "file://" + html_path],
        capture_output=True, text=True, timeout=120)
    if not os.path.exists(pdf_path):
        print(proc.stderr[-500:], file=sys.stderr)
        raise SystemExit(f"Chrome did not produce {pdf_path}")
    return pdf_path


want_pdf = "--pdf" in sys.argv
count = 0
for group, src in SRC_DIRS:
    if not os.path.isdir(src):
        continue
    out_dir = os.path.join(OUT_ROOT, group)
    os.makedirs(out_dir, exist_ok=True)
    for name in sorted(os.listdir(src)):
        if not name.endswith(".md"):
            continue
        with open(os.path.join(src, name)) as f:
            md = f.read()
        title = next((l[2:].strip() for l in md.split("\n") if l.startswith("# ")), "Budget")
        dest = os.path.join(out_dir, name[:-3] + ".html")
        with open(dest, "w") as f:
            f.write(page(title, render(md)))
        print("wrote", os.path.relpath(dest, ROOT))
        if want_pdf:
            print("wrote", os.path.relpath(to_pdf(dest), ROOT))
        count += 1

if count == 0:
    print("no markdown found", file=sys.stderr)
    sys.exit(1)
