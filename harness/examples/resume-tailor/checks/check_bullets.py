#!/usr/bin/env python3
"""Every bullet in a .docx falls inside a length band (a proxy for 'exactly two full lines').

    check_bullets.py --doc Resume.docx [--min-chars 190 --max-chars 215] [--skip-first N]
Exit 0 and prints PASS when every list paragraph is inside the band.
The band is a proxy; a rendered visual check is still the final word on line breaks.
"""
import argparse
import sys

from textio import docx_paragraphs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--doc", required=True)
    ap.add_argument("--min-chars", type=int, default=190)
    ap.add_argument("--max-chars", type=int, default=215)
    ap.add_argument("--skip-first", type=int, default=0,
                    help="ignore the first N list paragraphs (e.g. a skills list)")
    a = ap.parse_args()
    bullets = [p["text"].strip() for p in docx_paragraphs(a.doc) if p["is_list"] and p["text"].strip()]
    bullets = bullets[a.skip_first:]
    if not bullets:
        print("no bullets found")
        return 1
    bad = [(i, len(b), b) for i, b in enumerate(bullets, 1) if not a.min_chars <= len(b) <= a.max_chars]
    print(f"{len(bullets) - len(bad)}/{len(bullets)} bullets inside {a.min_chars}-{a.max_chars} chars")
    for i, n, b in bad:
        print(f"  bullet {i}: {n} chars -- {b[:70]}...")
    if bad:
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
