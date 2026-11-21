"""Render an editable resume source to PDF with what this Mac has installed.

* ``html``  — Playwright's Chromium (already used for career pages): ``page.pdf`` with the page's
  own ``@page`` size, backgrounds on.
* ``latex`` — ``tectonic``, ``latexmk``, ``xelatex`` (when the source loads ``fontspec``),
  ``pdflatex`` or ``lualatex`` from PATH, Homebrew or MacTeX (``/Library/TeX/texbin``). Shell
  escape is always off.
* ``docx``  — LibreOffice (``soffice --headless``), else Microsoft Word through AppleScript. Word is
  sandboxed: the file is staged in Word's own container so it never asks for folder access.

The source is compiled in a scratch copy of its folder, so classes / styles / images beside it
resolve and the stored source is never touched.
"""

from __future__ import annotations

import asyncio
import os
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path

RENDER_TIMEOUT_S = 120
_EXTRA_BIN = ("/Library/TeX/texbin", "/opt/homebrew/bin", "/usr/local/bin")
_SOFFICE_APP = Path("/Applications/LibreOffice.app/Contents/MacOS/soffice")
_WORD_APP = Path("/Applications/Microsoft Word.app")
_WORD_STAGE = Path.home() / "Library" / "Containers" / "com.microsoft.Word" / "Data" / "tmp" / "autoapply"


class RenderError(RuntimeError):
    """The renderer ran and failed (the message carries the tail of its log)."""


class RenderUnavailable(RenderError):
    """Nothing installed can render this kind of source."""


@dataclass(slots=True)
class Renderer:
    name: str | None
    hint: str | None = None


def _which(*names: str) -> str | None:
    path = os.pathsep.join([os.environ.get("PATH", ""), *_EXTRA_BIN])
    for n in names:
        found = shutil.which(n, path=path)
        if found:
            return found
    return None


def _latex_engine(source: Path | None = None) -> str | None:
    env = os.environ.get("AUTOAPPLY_LATEX")
    if env:
        return _which(env) or env
    wants_unicode = False
    if source is not None:
        try:
            text = source.read_text(encoding="utf-8", errors="replace")
            wants_unicode = "fontspec" in text
        except OSError:
            pass
    if wants_unicode:
        return _which("tectonic", "xelatex", "lualatex")
    return _which("tectonic", "pdflatex", "xelatex", "lualatex")


def _soffice() -> str | None:
    return _which("soffice", "libreoffice") or (str(_SOFFICE_APP) if _SOFFICE_APP.exists() else None)


def renderer_for(kind: str, source: Path | None = None) -> Renderer:
    if kind == "html":
        return Renderer("Chromium")
    if kind == "latex":
        engine = _latex_engine(source)
        if engine:
            return Renderer(Path(engine).name)
        return Renderer(None, "Install a TeX engine to render .tex resumes: `brew install tectonic` (or MacTeX).")
    if kind == "docx":
        if _soffice():
            return Renderer("LibreOffice")
        if _WORD_APP.exists():
            return Renderer("Microsoft Word")
        return Renderer(None, "Install LibreOffice (`brew install --cask libreoffice`) or Microsoft Word to render .docx resumes.")
    return Renderer(None, f"Unknown source kind {kind!r}.")


def page_count(pdf: Path) -> int | None:
    try:
        from pypdf import PdfReader

        return len(PdfReader(str(pdf)).pages)
    except Exception:  # noqa: BLE001
        return None


async def render_pdf(kind: str, source: Path, out_pdf: Path) -> int | None:
    """Render ``source`` to ``out_pdf``. Returns the page count. Raises :class:`RenderUnavailable`
    or :class:`RenderError`."""
    out_pdf.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="autoapply-render-") as tmp:
        work = Path(tmp) / "src"
        shutil.copytree(source.parent, work)
        src = work / source.name
        if kind == "html":
            produced = await _render_html(src, Path(tmp) / "out.pdf")
        elif kind == "latex":
            produced = await _render_latex(src)
        elif kind == "docx":
            produced = await _render_docx(src, Path(tmp))
        else:
            raise RenderUnavailable(f"unknown source kind {kind!r}")
        if not produced.is_file() or produced.stat().st_size == 0:
            raise RenderError("the renderer produced no PDF")
        shutil.copy2(produced, out_pdf)
    return page_count(out_pdf)


async def _run(cmd: list[str], cwd: Path, env: dict[str, str] | None = None) -> str:
    proc = await asyncio.create_subprocess_exec(
        *cmd, cwd=str(cwd), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
        stdin=asyncio.subprocess.DEVNULL, env={**os.environ, **(env or {})},
    )
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=RENDER_TIMEOUT_S)
    except TimeoutError as e:
        proc.kill()
        raise RenderError(f"{Path(cmd[0]).name} took longer than {RENDER_TIMEOUT_S}s") from e
    text = out.decode("utf-8", errors="replace")
    if proc.returncode != 0:
        raise RenderError(f"{Path(cmd[0]).name} failed:\n" + "\n".join(text.strip().splitlines()[-15:]))
    return text


async def _render_html(src: Path, out: Path) -> Path:
    from playwright.async_api import async_playwright

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True)
        try:
            page = await browser.new_page()
            await page.goto(src.as_uri(), wait_until="networkidle", timeout=RENDER_TIMEOUT_S * 1000)
            await page.pdf(path=str(out), print_background=True, prefer_css_page_size=True)
        finally:
            await browser.close()
    return out


async def _render_latex(src: Path) -> Path:
    engine = _latex_engine(src)
    if not engine:
        raise RenderUnavailable(renderer_for("latex").hint or "no TeX engine")
    name = Path(engine).name
    if name == "tectonic":
        await _run([engine, "--untrusted", "--outdir", str(src.parent), str(src)], src.parent)
    else:
        cmd = [engine, "-interaction=nonstopmode", "-halt-on-error", "-no-shell-escape", src.name]
        log = await _run(cmd, src.parent)
        if "Rerun" in log:
            await _run(cmd, src.parent)
    return src.with_suffix(".pdf")


async def _render_docx(src: Path, tmp: Path) -> Path:
    soffice = _soffice()
    if soffice:
        profile = (tmp / "lo-profile").as_uri()
        await _run([soffice, f"-env:UserInstallation={profile}", "--headless", "--convert-to", "pdf",
                    "--outdir", str(tmp), str(src)], tmp)
        return tmp / (src.stem + ".pdf")
    if _WORD_APP.exists():
        return await _render_docx_word(src, tmp)
    raise RenderUnavailable(renderer_for("docx").hint or "no .docx renderer")


def _applescript_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


async def _render_docx_word(src: Path, tmp: Path) -> Path:
    stage = _WORD_STAGE / tmp.name
    stage.mkdir(parents=True, exist_ok=True)
    try:
        doc = stage / src.name
        pdf = stage / (src.stem + ".pdf")
        shutil.copy2(src, doc)
        script = (
            'tell application "Microsoft Word"\n'
            f"  set theDoc to open file name {_applescript_str(str(doc))}\n"
            f"  save as theDoc file name {_applescript_str(str(pdf))} file format format PDF\n"
            "  close theDoc saving no\n"
            "end tell"
        )
        await _run(["osascript", "-e", script], tmp)
        out = tmp / pdf.name
        shutil.copy2(pdf, out)
        return out
    finally:
        shutil.rmtree(stage, ignore_errors=True)


__all__ = ["RenderError", "RenderUnavailable", "Renderer", "page_count", "render_pdf", "renderer_for"]
