#!/usr/bin/env python3
"""SessionStart hook (matcher: clear).

Re-surfaces the current project's handoff note (written by the clear-prep
skill) right after /clear wipes context. Silent no-op for any other source,
or when no handoff file exists.
"""
import json
import os
import sys

HANDOFF_REL_PATH = os.path.join(".claude", "handoff", "latest.md")


def build_output(payload):
    if payload.get("source") != "clear":
        return None
    cwd = payload.get("cwd")
    if not cwd:
        return None
    handoff_path = os.path.join(cwd, HANDOFF_REL_PATH)
    if not os.path.isfile(handoff_path):
        return None
    with open(handoff_path, "r", encoding="utf-8") as f:
        content = f.read().strip()
    if not content:
        return None
    return f"[clear-prep handoff — {handoff_path}]\n\n{content}"


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    try:
        output = build_output(payload)
    except Exception:
        return
    if output:
        print(output)


def _selftest():
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        handoff_dir = os.path.join(tmp, ".claude", "handoff")
        os.makedirs(handoff_dir)
        handoff_file = os.path.join(handoff_dir, "latest.md")
        with open(handoff_file, "w", encoding="utf-8") as f:
            f.write("# Handoff test\n- pending item")

        out = build_output({"source": "clear", "cwd": tmp})
        assert out is not None and "pending item" in out, "expected handoff content on clear+file present"

        out = build_output({"source": "startup", "cwd": tmp})
        assert out is None, "expected no output on non-clear source"

        with tempfile.TemporaryDirectory() as tmp2:
            out = build_output({"source": "clear", "cwd": tmp2})
            assert out is None, "expected no output when handoff file absent"

        out = build_output({"source": "clear", "cwd": ""})
        assert out is None, "expected no output when cwd is empty"

        with open(handoff_file, "w", encoding="utf-8") as f:
            f.write("   \n")
        out = build_output({"source": "clear", "cwd": tmp})
        assert out is None, "expected no output when handoff file is blank"

    print("session-resume-handoff.py: selftest OK")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()
