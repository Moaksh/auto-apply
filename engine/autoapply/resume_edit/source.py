"""Editable resume sources: split a file into segments and write edited segments back.

A source is the file the resume PDF is made from: HTML, LaTeX or a Word ``.docx``. The editor
and the tailor only ever change segment *text*; layout, fonts and markup around it stay as the
user wrote them.

* ``html``  — every block element with no block inside it (``p``, ``li``, ``h1``…, ``td``, a leaf
  ``div``) is a segment. An edited segment becomes plain text inside its innermost single-child
  wrapper, so a ``<li><span class=x>…</span></li>`` keeps its span; inline markup *inside* an
  edited segment (a bold lead-in, a link) is dropped. Unedited segments are untouched.
* ``latex`` — every line of the document body with visible text is a segment, raw markup
  included. A trailing ``%`` comment is kept aside and put back. New text may not bring commands
  the line didn't have (beyond a few formatting ones), braces must balance, and stray ``% # & $ _``
  are escaped, so an edit can't break the build or reach outside the document.
* ``docx``  — every ``<w:p>`` paragraph of ``word/document.xml`` with text is a segment. Tabs and
  line breaks inside a paragraph show as ``\\t`` / ``\\n`` and must survive an edit (they hold
  right-aligned dates in place); each tab-separated part goes into the first run of its part, so
  that run's formatting is kept. The XML is edited as text, never re-serialised, so Word sees the
  same namespaces and markup it wrote.
"""

from __future__ import annotations

import html
import re
import shutil
import zipfile
from dataclasses import dataclass
from pathlib import Path

from bs4 import BeautifulSoup, NavigableString, Tag

KINDS = ("html", "latex", "docx")
_EXT_KIND = {".html": "html", ".htm": "html", ".tex": "latex", ".docx": "docx"}
#: Kinds of local file a source may use to render (classes, styles, images, fonts).
_ASSET_EXTS = frozenset({".cls", ".sty", ".bst", ".css", ".png", ".jpg", ".jpeg", ".svg", ".gif", ".otf", ".ttf", ".woff", ".woff2"})
MAX_ASSET_BYTES = 20 * 1024 * 1024


class SourceError(ValueError):
    """The source can't be read, or an edit can't be applied to it."""


@dataclass(slots=True)
class Segment:
    id: str
    text: str


def kind_for(path: Path | str) -> str:
    kind = _EXT_KIND.get(Path(path).suffix.lower())
    if kind is None:
        raise SourceError("The editable source must be an .html, .tex or .docx file.")
    return kind


def store_source(src: Path, dest_dir: Path) -> Path:
    """Copy ``src`` and the local files it uses (a custom class or package, included files,
    images, stylesheets) into ``dest_dir``. Only files the source names are copied, never the
    rest of its folder. Returns the stored source path."""
    if not src.is_file():
        raise FileNotFoundError(f"source file not found: {src}")
    kind = kind_for(src)
    dest_dir.mkdir(parents=True, exist_ok=True)
    total = 0
    for rel in referenced_files(src, kind):
        target = (dest_dir / rel).resolve()
        if not target.is_relative_to(dest_dir.resolve()):
            continue
        total += (src.parent / rel).stat().st_size
        if total > MAX_ASSET_BYTES:
            break
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src.parent / rel, target)
    dest = dest_dir / src.name
    shutil.copy2(src, dest)
    return dest


_TEX_REFS_RX = re.compile(
    r"\\(documentclass|usepackage|RequirePackage|input|include|includegraphics|bibliography|addbibresource|setmainfont)"
    r"\*?(?:\[[^\]]*\])?\{([^}]*)\}"
)
_TEX_EXTS = {"documentclass": (".cls",), "usepackage": (".sty",), "RequirePackage": (".sty",), "input": ("", ".tex"),
             "include": (".tex",), "includegraphics": ("", ".pdf", ".png", ".jpg", ".jpeg", ".eps"),
             "bibliography": (".bib",), "addbibresource": ("",), "setmainfont": ("", ".otf", ".ttf")}
_HTML_REF_RX = re.compile(r"""(?:src|href)\s*=\s*["']([^"'#?]+)["']|url\(\s*["']?([^"')#?]+)["']?\s*\)""", re.I)


def referenced_files(src: Path, kind: str) -> list[Path]:
    """Local files (relative to the source's folder, inside it) that ``src`` names and that exist."""
    if kind == "docx":
        return []
    text = src.read_text(encoding="utf-8", errors="replace")
    candidates: list[str] = []
    if kind == "latex":
        for cmd, arg in _TEX_REFS_RX.findall(text):
            for name in (a.strip() for a in arg.split(",")):
                if name:
                    candidates += [name + ext for ext in _TEX_EXTS[cmd]]
    else:
        for a, b in _HTML_REF_RX.findall(text):
            ref = (a or b).strip()
            if ref and not re.match(r"^[a-z][a-z0-9+.-]*:|^//", ref, re.I):
                candidates.append(ref)
    root = src.parent.resolve()
    out: list[Path] = []
    for c in dict.fromkeys(candidates):
        p = (root / c).resolve()
        if p != src.resolve() and p.is_file() and p.is_relative_to(root) and p.suffix.lower() in _ASSET_EXTS | {".tex", ".bib", ".pdf", ".eps"}:
            out.append(p.relative_to(root))
    return out


def copy_source_dir(src: Path, dest_dir: Path) -> Path:
    """Copy a stored source and everything stored beside it (only what :func:`store_source`
    kept) into a fresh ``dest_dir``; returns the new source path."""
    shutil.copytree(src.parent, dest_dir, dirs_exist_ok=True)
    return dest_dir / src.name


def read_segments(path: Path | str, kind: str | None = None) -> list[Segment]:
    path = Path(path)
    kind = kind or kind_for(path)
    if kind == "html":
        return [Segment(sid, _el_text(el)) for sid, el in _html_segments(_soup(path.read_text(encoding="utf-8", errors="replace")))]
    if kind == "latex":
        return [Segment(sid, body) for sid, (_i, _indent, body, _comment) in _latex_segments(path.read_text(encoding="utf-8", errors="replace"))]
    if kind == "docx":
        xml = _docx_xml(path)
        return [Segment(sid, text) for sid, (_s, _e, text) in _docx_segments(xml)]
    raise SourceError(f"unknown source kind {kind!r}")


def plain_text(text: str, kind: str) -> str:
    """What a reader sees in a segment (LaTeX markup removed; tabs as spaces)."""
    if kind == "latex":
        return latex_visible(text)
    return re.sub(r"[ \t]+", " ", text).strip()


def check_edit(before: str, after: str, kind: str) -> str | None:
    """Why ``after`` can't replace ``before`` in this kind of source (None: it can)."""
    if not after.strip():
        return "empty text"
    if kind == "docx":
        if after.count("\t") != before.count("\t") or after.count("\n") != before.count("\n"):
            return "tabs and line breaks must stay as they are"
    elif kind == "latex":
        if "\n" in after.strip():
            return "a LaTeX segment is one line"
        if not _braces_balanced(after):
            return "unbalanced braces"
        new_cmds = set(_LATEX_CMD_RX.findall(after)) - set(_LATEX_CMD_RX.findall(before)) - _LATEX_SAFE_CMDS
        if new_cmds:
            return "new LaTeX commands: " + ", ".join(sorted("\\" + c for c in new_cmds))
    elif kind == "html":
        if "\n" in after.strip():
            return "a segment is one paragraph"
    return None


def apply_edits(src: Path, dest: Path, edits: dict[str, str], kind: str | None = None) -> None:
    """Write ``src`` with ``edits`` (segment id -> new text) applied to ``dest``. Raises
    :class:`SourceError` for an unknown segment id or an edit :func:`check_edit` rejects."""
    kind = kind or kind_for(src)
    if kind == "html":
        soup = _soup(src.read_text(encoding="utf-8", errors="replace"))
        by_id = dict(_html_segments(soup))
        _require_ids(edits, by_id)
        for sid, text in edits.items():
            el = by_id[sid]
            _reject(sid, check_edit(_el_text(el), text, kind))
            if text.strip() == _el_text(el):
                continue
            target = _innermost(el)
            target.clear()
            target.append(NavigableString(text.strip()))
        dest.write_text(str(soup), encoding="utf-8")
    elif kind == "latex":
        raw = src.read_text(encoding="utf-8", errors="replace")
        lines = raw.split("\n")
        by_id = {sid: seg for sid, seg in _latex_segments(raw)}
        _require_ids(edits, by_id)
        for sid, text in edits.items():
            i, indent, body, comment = by_id[sid]
            _reject(sid, check_edit(body, text, kind))
            if text.strip() == body:
                continue
            lines[i] = indent + latex_escape_extras(body, text.strip()) + comment
        dest.write_text("\n".join(lines), encoding="utf-8")
    elif kind == "docx":
        xml = _docx_xml(src)
        segs = {sid: (s, e, text) for sid, (s, e, text) in _docx_segments(xml)}
        _require_ids(edits, segs)
        out, pos = [], 0
        for sid, (s, e, before) in sorted(segs.items(), key=lambda kv: kv[1][0]):
            if sid not in edits or edits[sid] == before:
                continue
            _reject(sid, check_edit(before, edits[sid], kind))
            out += [xml[pos:s], _docx_set_text(xml[s:e], edits[sid])]
            pos = e
        out.append(xml[pos:])
        _docx_write(src, dest, "".join(out))
    else:
        raise SourceError(f"unknown source kind {kind!r}")


def _require_ids(edits: dict[str, str], known: dict) -> None:
    unknown = [sid for sid in edits if sid not in known]
    if unknown:
        raise SourceError(f"unknown segment(s): {', '.join(unknown[:5])}")


def _reject(sid: str, why: str | None) -> None:
    if why:
        raise SourceError(f"{sid}: {why}")


# -------------------------------------------------------------------------------------
# HTML
# -------------------------------------------------------------------------------------

_BLOCK = frozenset({
    "p", "li", "h1", "h2", "h3", "h4", "h5", "h6", "td", "th", "dt", "dd", "div", "section", "header",
    "footer", "blockquote", "figcaption", "address", "article", "aside", "main", "ul", "ol", "table",
    "tr", "tbody", "thead", "dl", "pre", "nav", "body", "html",
})
_SKIP = frozenset({"script", "style", "head", "title", "noscript", "template", "svg"})


def _soup(text: str) -> BeautifulSoup:
    return BeautifulSoup(text, "html.parser")


def _el_text(el: Tag) -> str:
    return re.sub(r"\s+", " ", el.get_text(" ")).replace(" ,", ",").replace(" .", ".").strip()


def _html_segments(soup: BeautifulSoup) -> list[tuple[str, Tag]]:
    out: list[tuple[str, Tag]] = []
    for el in soup.find_all(True):
        if el.name not in _BLOCK or el.name in {"ul", "ol", "table", "tr", "tbody", "thead", "dl", "body", "html"}:
            continue
        if any(p.name in _SKIP for p in el.parents if isinstance(p, Tag)):
            continue
        if el.find(lambda t: isinstance(t, Tag) and t.name in _BLOCK):
            continue
        if _el_text(el):
            out.append((f"s{len(out) + 1}", el))
    return out


def _innermost(el: Tag) -> Tag:
    """Descend through single-child wrappers (``<li><span>…</span></li>`` -> the span)."""
    while True:
        kids = [c for c in el.children if not (isinstance(c, NavigableString) and not c.strip())]
        if len(kids) == 1 and isinstance(kids[0], Tag) and kids[0].name not in {"br", "img"}:
            el = kids[0]
            continue
        return el


# -------------------------------------------------------------------------------------
# LaTeX
# -------------------------------------------------------------------------------------

_LATEX_CMD_RX = re.compile(r"\\([A-Za-z@]+)")
#: Formatting commands an edit may introduce even when the line didn't use them.
_LATEX_SAFE_CMDS = frozenset({"textbf", "textit", "emph", "underline", "textsc", "texttt", "small", "footnotesize"})
_COMMENT_RX = re.compile(r"(?<!\\)%")
_LATEX_ARG_CMDS_RX = re.compile(
    r"\\(?:begin|end|usepackage|documentclass|vspace|hspace|setlength|addtolength|input|include|label|ref|"
    r"pagestyle|thispagestyle|newcommand|renewcommand|definecolor|color|geometry|fontsize|setmainfont)\*?"
    r"(?:\[[^\]]*\]|\{[^{}]*\})*"
)


def latex_visible(text: str) -> str:
    s = _COMMENT_RX.split(text, 1)[0]
    s = re.sub(r"\\(href)\{[^}]*\}", " ", s)  # the URL of \href{url}{text} is not visible text
    s = _LATEX_ARG_CMDS_RX.sub(" ", s)  # \begin{itemize}, \vspace{2pt}: arguments that are not text
    s = re.sub(r"\\[A-Za-z@]+\*?(\[[^\]]*\])?", " ", s)
    s = re.sub(r"(?<!\\)\$[^$]*(?<!\\)\$", " ", s)  # inline math
    s = re.sub(r"\\([&%$#_{}])", r"\1", s)
    s = s.replace("~", " ").replace("---", "—").replace("--", "–").replace("``", '"').replace("''", '"')
    s = re.sub(r"[{}]|\\\\", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def _braces_balanced(s: str) -> bool:
    depth = 0
    escaped = False
    for ch in s:
        if escaped:
            escaped = False
            continue
        if ch == "\\":
            escaped = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


def _unescaped(ch: str, s: str) -> int:
    return len(re.findall(r"(?<!\\)" + re.escape(ch), s))


def latex_escape_extras(before: str, after: str) -> str:
    """Escape ``% #`` always, and ``& $ _`` when the line had none unescaped (a tabular ``&`` or
    math ``$`` the line already used stays as it is)."""
    for ch in "%#":
        after = re.sub(r"(?<!\\)" + re.escape(ch), "\\\\" + ch, after)
    for ch in "&$_":
        if _unescaped(ch, before) == 0:
            after = re.sub(r"(?<!\\)" + re.escape(ch), "\\\\" + ch, after)
    return after


def _latex_segments(raw: str) -> list[tuple[str, tuple[int, str, str, str]]]:
    """``(id, (line index, indent, body, trailing comment))`` for each line with visible text."""
    lines = raw.split("\n")
    start, end = 0, len(lines)
    for i, line in enumerate(lines):
        if re.match(r"\s*\\begin\{document\}", line):
            start = i + 1
        elif re.match(r"\s*\\end\{document\}", line):
            end = i
            break
    out: list[tuple[str, tuple[int, str, str, str]]] = []
    for i in range(start, end):
        line = lines[i]
        indent = line[: len(line) - len(line.lstrip())]
        stripped = line.strip()
        if not stripped or stripped.startswith("%"):
            continue
        m = _COMMENT_RX.search(stripped)
        body = stripped[: m.start()].rstrip() if m else stripped
        comment = stripped[len(body):]
        if len(re.findall(r"[A-Za-z]", latex_visible(body))) < 2:
            continue
        out.append((f"s{len(out) + 1}", (i, indent, body, comment)))
    return out


# -------------------------------------------------------------------------------------
# .docx
# -------------------------------------------------------------------------------------

_DOC_PART = "word/document.xml"
_P_RX = re.compile(r"<w:p(?=[\s>])[^>]*(?<!/)>.*?</w:p>", re.S)
_PPR_RX = re.compile(r"<w:pPr\b.*?</w:pPr>", re.S)
_T_RX = re.compile(r"<w:t(?:\s[^>]*)?(?:/>|>(.*?)</w:t>)", re.S)
_SEP_RX = re.compile(r"<w:(tab|br|cr)\b[^>]*/>")
_TOKEN_RX = re.compile(r"<w:t(?:\s[^>]*)?(?:/>|>(?:.*?)</w:t>)|<w:(?:tab|br|cr)\b[^>]*/>", re.S)


def _docx_xml(path: Path) -> str:
    try:
        with zipfile.ZipFile(path) as z:
            return z.read(_DOC_PART).decode("utf-8")
    except (KeyError, zipfile.BadZipFile) as e:
        raise SourceError(f"not a Word document: {path.name}") from e


def _docx_write(src: Path, dest: Path, xml: str) -> None:
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = xml.encode("utf-8") if item.filename == _DOC_PART else zin.read(item.filename)
            zout.writestr(item, data)
    tmp.replace(dest)


def _docx_tokens(p_xml: str) -> tuple[int, list[re.Match[str]]]:
    """Offset where runs start (after ``w:pPr``, whose ``w:tabs`` are tab stops, not tabs) and
    the text / separator tokens of the paragraph."""
    ppr = _PPR_RX.search(p_xml)
    off = ppr.end() if ppr else 0
    return off, list(_TOKEN_RX.finditer(p_xml, off))


def _token_text(tok: re.Match[str]) -> str:
    s = tok.group(0)
    if s.startswith("<w:tab"):
        return "\t"
    if s.startswith(("<w:br", "<w:cr")):
        return "\n"
    m = _T_RX.match(s)
    return html.unescape(m.group(1) or "") if m else ""


def _docx_segments(xml: str) -> list[tuple[str, tuple[int, int, str]]]:
    out: list[tuple[str, tuple[int, int, str]]] = []
    for m in _P_RX.finditer(xml):
        chunk = m.group(0)
        if re.search(r"<w:p[\s>]", chunk[4:]):  # a text box nested inside: not editable as one paragraph
            continue
        _off, toks = _docx_tokens(chunk)
        text = "".join(_token_text(t) for t in toks)
        if text.strip():
            out.append((f"s{len(out) + 1}", (m.start(), m.end(), text)))
    return out


def _docx_set_text(p_xml: str, text: str) -> str:
    """Put ``text`` into the paragraph: each tab / break-separated part goes into the first
    ``w:t`` of the same part (keeping that run's formatting); other ``w:t`` of the part empty."""
    _off, toks = _docx_tokens(p_xml)
    parts = re.split(r"[\t\n]", text)
    groups: list[list[re.Match[str]]] = [[]]
    for t in toks:
        if _SEP_RX.match(t.group(0)):
            groups.append([])
        else:
            groups[-1].append(t)
    if len(groups) != len(parts):
        raise SourceError("tabs and line breaks must stay as they are")
    repl: list[tuple[int, int, str]] = []
    for group, part in zip(groups, parts, strict=True):
        if not group:
            if part.strip():
                raise SourceError("text can't go where the paragraph has none")
            continue
        for j, t in enumerate(group):
            value = html.escape(part, quote=False) if j == 0 else ""
            repl.append((t.start(), t.end(), f'<w:t xml:space="preserve">{value}</w:t>'))
    out, pos = [], 0
    for s, e, r in repl:
        out += [p_xml[pos:s], r]
        pos = e
    out.append(p_xml[pos:])
    return "".join(out)


__all__ = [
    "KINDS", "Segment", "SourceError", "apply_edits", "check_edit", "copy_source_dir", "kind_for",
    "latex_visible", "plain_text", "read_segments", "store_source",
]
