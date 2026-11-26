"""Run gamdl 4's command line and report its per-track progress to Gamdl Studio.

gamdl 4 draws its progress with a transient Rich display, which prints nothing
when the output is a pipe: the app would only learn about a track once it is
finished. This wrapper hooks that display (gamdl.cli.progress.RipProgress) and
prints one JSON line per event, prefixed with MARKER, then hands the arguments
to gamdl's own entry point. gamdl's regular output is left untouched.

If the hooks can't be installed (a later gamdl renamed the display), gamdl runs
as is and the app falls back to the permanent lines gamdl prints.

Usage: python -I -u gamdl_bridge.py rip [gamdl options] URL...

Kept compatible with Python 3.9 so the test suite can run it with the system
interpreter against a stub gamdl package.
"""

import json
import sys
import time

MARKER = "@gamdl-studio "
# gamdl reports transfer progress for every media segment; the app redraws at
# a human pace, so one line every quarter second per track is plenty.
PROGRESS_INTERVAL = 0.25


def emit(payload):
    sys.stdout.write(MARKER + json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def install_hooks():
    """Wraps RipProgress.add/event/finish. Returns False if they are missing."""
    try:
        from gamdl.cli.progress import RipProgress
    except Exception:
        return False

    original_add = getattr(RipProgress, "add", None)
    original_event = getattr(RipProgress, "event", None)
    original_finish = getattr(RipProgress, "finish", None)
    if not all(callable(f) for f in (original_add, original_event, original_finish)):
        return False

    last_sent = {}

    def add(self, occurrence, title, *args, **kwargs):
        try:
            emit({"e": "track", "i": int(occurrence), "title": str(title)})
        except Exception:
            pass
        return original_add(self, occurrence, title, *args, **kwargs)

    def event(self, occurrence, title, download_event, *args, **kwargs):
        try:
            progress = getattr(download_event, "progress", None)
            if progress is not None:
                percent = float(progress.percentage)
                now = time.monotonic()
                # monotonic() has no fixed origin (it starts near 0 with the
                # process on some Pythons): a track's first event always goes out.
                previous = last_sent.get(occurrence)
                if percent >= 100 or previous is None or now - previous >= PROGRESS_INTERVAL:
                    last_sent[occurrence] = now
                    emit(
                        {
                            "e": "progress",
                            "i": int(occurrence),
                            "pct": percent,
                            "bytes": getattr(progress, "emitted_bytes", None),
                            "total": getattr(progress, "total_bytes", None),
                            "elapsed": getattr(progress, "elapsed_seconds", None),
                        }
                    )
        except Exception:
            pass
        return original_event(self, occurrence, title, download_event, *args, **kwargs)

    def finish(self, occurrence, title, status, *args, **kwargs):
        # gamdl lists failures only after its final summary: report them now.
        try:
            if status == "failed":
                message = args[0] if args else kwargs.get("message")
                emit({"e": "failed", "i": int(occurrence), "title": str(title), "message": message})
        except Exception:
            pass
        return original_finish(self, occurrence, title, status, *args, **kwargs)

    RipProgress.add = add
    RipProgress.event = event
    RipProgress.finish = finish
    return True


def gamdl_entry_point():
    """gamdl's console script, wherever this version of gamdl declares it."""
    try:
        from importlib.metadata import entry_points

        found = entry_points()
        if hasattr(found, "select"):
            candidates = list(found.select(group="console_scripts", name="gamdl"))
        else:  # Python 3.9
            candidates = [e for e in found.get("console_scripts", []) if e.name == "gamdl"]
        if candidates:
            return candidates[0].load()
    except Exception:
        pass
    from gamdl.cli.main import main

    return main


def main():
    # -I ignores PYTHONIOENCODING; gamdl prints ✓, ↷, → and track titles.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass
    install_hooks()
    entry = gamdl_entry_point()
    sys.argv = ["gamdl"] + sys.argv[1:]
    return entry()


if __name__ == "__main__":
    sys.exit(main())
