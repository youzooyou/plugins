#!/usr/bin/env python3
"""SessionStart hook (matcher: clear).

Re-surfaces the current project's handoff note (written by the clear-prep
skill) right after /clear wipes context. Silent no-op for any other source,
or when no handoff file exists.
"""
import json
import os
import stat
import sys

HANDOFF_REL_PATH = os.path.join(".claude", "handoff", "latest.md")
MAX_HANDOFF_BYTES = 262144  # 256 KiB -- generous for a handoff note, bounded


def build_output(payload):
    if payload.get("source") != "clear":
        return None
    cwd = payload.get("cwd")
    if not cwd:
        return None
    handoff_path = os.path.join(cwd, HANDOFF_REL_PATH)
    # Open with O_NOFOLLOW first, then stat/read the already-open descriptor
    # -- checking islink()/getsize() on the *path* and only afterward
    # opening it leaves a race window where the path could be swapped for a
    # symlink (or a larger file) in between. An open file descriptor always
    # refers to the one inode we actually validate below, regardless of
    # what happens to the path afterward.
    # O_NONBLOCK matters only for a FIFO/special file: opening one O_RDONLY
    # without it blocks until a writer connects (or forever) -- the earlier
    # os.path.isfile() check incidentally avoided this by rejecting FIFOs
    # before ever opening them, a property this open-first approach must
    # preserve explicitly. O_NONBLOCK has no effect on a regular file open.
    try:
        fd = os.open(handoff_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_HANDOFF_BYTES:
            return None
        with os.fdopen(fd, "r", encoding="utf-8") as f:
            fd = None  # ownership transferred to the file object
            content = f.read(MAX_HANDOFF_BYTES).strip()
    finally:
        if fd is not None:
            os.close(fd)
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
    import signal
    import tempfile

    with tempfile.TemporaryDirectory() as tmp3:
        fifo_dir = os.path.join(tmp3, ".claude", "handoff")
        os.makedirs(fifo_dir)
        os.mkfifo(os.path.join(fifo_dir, "latest.md"))

        def _timeout_handler(signum, frame):
            raise TimeoutError("build_output blocked on a FIFO -- O_NONBLOCK regression")

        old_handler = signal.signal(signal.SIGALRM, _timeout_handler)
        signal.alarm(2)
        try:
            out = build_output({"source": "clear", "cwd": tmp3})
            assert out is None, "expected no output when handoff path is a FIFO"
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, old_handler)

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
