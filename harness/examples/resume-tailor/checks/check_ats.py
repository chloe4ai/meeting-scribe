#!/usr/bin/env python3
"""The .docx and .pdf parse to the same words, with standard sections and no ATS traps.

    check_ats.py --docx Resume.docx --pdf Resume.pdf \
        [--sections "OBJECTIVE,CORE SKILLS,PROFESSIONAL EXPERIENCE,EDUCATION"] [--min-similarity 0.95]
Exit 0 and prints PASS when: both files extract, word-level similarity >= threshold, every
section heading is found in the PDF text, and the .docx has no tables, text boxes, images,
or text that exists only in headers/footers.
"""
import argparse
import difflib
import re
import sys

from textio import any_text, docx_layout_flags, normalize


def words(text):
    return re.findall(r"[a-z0-9$%+.#/&-]+", normalize(text))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--docx", required=True)
    ap.add_argument("--pdf", required=True)
    ap.add_argument("--sections", default="OBJECTIVE,CORE SKILLS,PROFESSIONAL EXPERIENCE,EDUCATION")
    ap.add_argument("--min-similarity", type=float, default=0.95)
    a = ap.parse_args()
    problems = []
    dw, pw = words(any_text(a.docx)), words(any_text(a.pdf))
    if not dw or not pw:
        problems.append("one of the files extracted to no text")
    sim = difflib.SequenceMatcher(None, dw, pw, autojunk=False).ratio() if dw and pw else 0.0
    print(f"docx/pdf word similarity {sim:.3f} ({len(dw)} vs {len(pw)} words)")
    if sim < a.min_similarity:
        problems.append(f"similarity {sim:.3f} < {a.min_similarity}")
    pdf_norm = normalize(any_text(a.pdf))
    for s in [x.strip() for x in a.sections.split(",") if x.strip()]:
        if normalize(s) not in pdf_norm:
            problems.append(f"section heading not found in PDF text: {s}")
    flags = docx_layout_flags(a.docx)
    for k in ("tables", "text_boxes", "images"):
        if flags[k]:
            problems.append(f"docx contains {flags[k]} {k.replace('_', ' ')}")
    if flags["header_footer_text"]:
        problems.append(f"text in header/footer (ATS may drop it): {flags['header_footer_text'][:60]}")
    for p in problems:
        print("  " + p)
    if problems:
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
