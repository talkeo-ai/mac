#!/usr/bin/env python3
"""Replace the current selection in the focused iTerm2 session's input line.

Talkeo's "Replace" for terminals. AppKit Accessibility only exposes the visual
scrollback (chrome + wrap artifacts), which makes in-place editing unreliable.
The iTerm2 Python API instead gives us the real cursor coordinate, the selection
coordinates, and per-line `hard_eol` (so soft wraps vs real newlines are
distinguishable). With those we can navigate the input cursor precisely.

Invoked as:  python iterm_replace.py "<original selection>" "<improved text>"
Exits 0 on a performed edit, non-zero otherwise (the app falls back to Copy).
Everything observed is logged to /tmp/talkeo_iterm.log so the algorithm can be
tuned from real data.
"""
import sys
import iterm2

LOG = "/tmp/talkeo_iterm.log"


def log(msg):
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(msg + "\n")


async def main(connection, argv):
    original = argv[1] if len(argv) > 1 else ""
    improved = argv[2] if len(argv) > 2 else ""

    app = await iterm2.async_get_app(connection)
    window = app.current_terminal_window
    if window is None:
        log("no current window"); print("no-window"); return 2
    session = window.current_tab.current_session
    if session is None:
        log("no current session"); print("no-session"); return 2

    contents = await session.async_get_screen_contents()
    cursor = contents.cursor_coord
    n = contents.number_of_lines
    above = contents.number_of_lines_above_screen

    log("==== talkeo iterm_replace ====")
    log(f"original={original!r}")
    log(f"improved={improved!r}")
    log(f"cursor=({cursor.x},{cursor.y}) screen_lines={n} lines_above={above}")

    # Selection (coordinates are absolute, incl. scrollback overflow).
    try:
        sel = await session.async_get_selection()
        sel_text = await session.async_get_selection_text(sel)
    except Exception as e:  # noqa: BLE001
        sel, sel_text = None, None
        log(f"selection error: {e}")
    log(f"selection_text={sel_text!r}")
    if sel is not None:
        for i, sub in enumerate(getattr(sel, "subSelections", []) or []):
            cr = getattr(sub, "coordRange", None) or getattr(sub, "range", None)
            log(f"sub[{i}] range={cr}")

    # Dump the lines around the cursor with their wrap flag, so we can see how
    # Claude Code renders the input (prompt, hanging indent, padding, wraps).
    start = max(0, cursor.y - 8)
    for i in range(start, min(n, cursor.y + 2)):
        line = contents.line(i)
        log(f"line[{i}] hard_eol={line.hard_eol} str={line.string!r}")

    # First pass: just observe. Don't risk a wrong edit until the coordinate
    # math is confirmed against this log. (We still leave the improved text on
    # the clipboard via the app's fallback.)
    print("logged")
    return 1


def run():
    argv = list(sys.argv)

    async def _main(connection):
        code = await main(connection, argv)
        raise SystemExit(code if isinstance(code, int) else 0)

    iterm2.run_until_complete(_main)


if __name__ == "__main__":
    run()
