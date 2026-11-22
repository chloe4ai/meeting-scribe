"""Text extraction shared by the resume checks. Stdlib only (pdftotext used if present)."""
from __future__ import annotations

import re
import shutil
import subprocess
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"


def docx_paragraphs(path: str | Path) -> list[dict]:
    """Return [{'text', 'style', 'is_list'}] for each body paragraph of a .docx."""
    with zipfile.ZipFile(path) as z:
        root = ET.fromstring(z.read("word/document.xml"))
    out = []
    for p in root.iter(f"{W}p"):
        text = "".join(t.text or "" for t in p.iter(f"{W}t"))
        ppr = p.find(f"{W}pPr")
        style, is_list = "", False
        if ppr is not None:
            st = ppr.find(f"{W}pStyle")
            style = st.get(f"{W}val", "") if st is not None else ""
            is_list = ppr.find(f"{W}numPr") is not None or "list" in style.lower()
        if not is_list and re.match(r"^\s*[•●▪\-–]\s+", text):
            is_list = True
        out.append({"text": text, "style": style, "is_list": is_list})
    return out


def docx_layout_flags(path: str | Path) -> dict:
    """Things ATS parsers commonly drop: tables, text boxes, text living only in headers/footers."""
    with zipfile.ZipFile(path) as z:
        body = z.read("word/document.xml").decode("utf8", "ignore")
        header_text = ""
        for name in z.namelist():
            if re.match(r"word/(header|footer)\d*\.xml", name):
                root = ET.fromstring(z.read(name))
                header_text += " ".join(t.text or "" for t in root.iter(f"{W}t"))
    return {
        "tables": body.count("<w:tbl>") + body.count("<w:tbl "),
        "text_boxes": body.count("w:txbxContent"),
        "images": body.count("<w:drawing"),
        "header_footer_text": header_text.strip(),
    }


def pdf_text(path: str | Path) -> str:
    if shutil.which("pdftotext"):
        return subprocess.run(["pdftotext", "-layout", str(path), "-"],
                              capture_output=True, text=True, check=True).stdout
    try:
        from pypdf import PdfReader  # type: ignore
    except ImportError as e:
        raise SystemExit("Need pdftotext (poppler) or pypdf to read PDFs") from e
    return "\n".join(page.extract_text() or "" for page in PdfReader(str(path)).pages)


def any_text(path: str | Path) -> str:
    path = Path(path)
    suffix = path.suffix.lower()
    if suffix == ".docx":
        return "\n".join(p["text"] for p in docx_paragraphs(path))
    if suffix == ".pdf":
        return pdf_text(path)
    return path.read_text(errors="ignore")


def normalize(text: str) -> str:
    text = text.replace("’", "'").replace("–", "-").replace("—", "-")
    return re.sub(r"\s+", " ", text).strip().lower()
