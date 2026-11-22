#!/usr/bin/env python3
"""Every required term appears in the document.

Keywords file: one term per line. 'A | B' means either spelling counts.
'#' starts a comment. Use it twice: once for the JD's keywords, once for facts that
must survive tailoring untouched (employers, titles, dates, degrees).

    check_keywords.py --keywords jd_keywords.txt --doc Resume.docx [--min 100]
Exit 0 and prints PASS when coverage >= --min percent.
"""
import argparse
import re
import sys

from textio import any_text, normalize


def load_terms(path):
    terms = []
    for line in open(path, encoding="utf8"):
        line = line.split("#", 1)[0].strip()
        if line:
            terms.append([alt.strip() for alt in line.split("|") if alt.strip()])
    return terms


def present(term: str, text: str) -> bool:
    t = normalize(term)
    return re.search(r"(?<![a-z0-9])" + re.escape(t) + r"(?![a-z0-9])", text) is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keywords", required=True)
    ap.add_argument("--doc", required=True)
    ap.add_argument("--min", type=float, default=100.0)
    a = ap.parse_args()
    text = normalize(any_text(a.doc))
    terms = load_terms(a.keywords)
    missing = [alts for alts in terms if not any(present(t, text) for t in alts)]
    cov = 100.0 * (len(terms) - len(missing)) / max(len(terms), 1)
    print(f"coverage {cov:.1f}% ({len(terms) - len(missing)}/{len(terms)})")
    for alts in missing:
        print("  missing: " + " | ".join(alts))
    if cov >= a.min:
        print("PASS")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
