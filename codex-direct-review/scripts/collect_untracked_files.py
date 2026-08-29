#!/usr/bin/env python3
"""Collects untracked-file content for run-codex-review.sh's --uncommitted
scope, as a standalone subprocess.

This logic used to live inline in run-codex-review.sh (bash). It was the
single most bug-prone part of that file across many rounds of adversarial
review: NUL-byte truncation through bash command substitution, a
false-positive binary detector, a check-then-open symlink TOCTOU that bash
could only detect after the fact (no portable no-follow-open primitive), and
a whole signal-safety subsystem (a temp-file registry, PID tracking, a
custom bounded-read loop) built just to make a backgrounded `head` process
safely killable on interrupt. None of those bug classes can occur here:
Python's `bytes` handle NUL natively, and `os.open(..., os.O_NOFOLLOW)`
prevents a symlink swap outright instead of detecting one after the read.

Usage: collect_untracked_files.py CWD [--deadline-secs N] [--max-bytes N]

Prints accumulated diff-text fragments to stdout (each prefixed by a
newline, matching the bash wrapper's existing DIFF_TEXT convention -- the
prompt-building code downstream does not need to change). Exit codes:
  0 -> success (collection completed, possibly with zero untracked files)
  1 -> fatal error (e.g. `git ls-files` failed) -- detail on stderr
  2 -> incomplete (the aggregate deadline was exceeded before every
       untracked file was examined) -- the CALLER must treat this as a hard
       failure, not proceed to a verdict on a partially-examined scope.
"""
import argparse
import os
import stat
import subprocess
import sys
import time

DEFAULT_DEADLINE_SECS = 30
DEFAULT_MAX_BYTES = 1024 * 1024


def list_untracked_files(cwd):
    """Returns (files, error_detail). error_detail is None on success.

    Uses subprocess.run with no shell involved -- argument-array exec, not a
    shell command string, so there is no injection risk and no way for
    stdout/stderr to be accidentally merged (the exact c1 bug this file's
    bash predecessor once had via `2>&1`)."""
    try:
        result = subprocess.run(
            ["git", "ls-files", "-z", "--others", "--exclude-standard"],
            cwd=cwd,
            capture_output=True,
            check=False,
        )
    except OSError as exc:
        return None, f"failed to run git: {exc}"
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        return None, f"failed to enumerate untracked files: {detail}"
    raw = result.stdout
    files = [f.decode("utf-8", errors="replace") for f in raw.split(b"\0") if f]
    return files, None


def format_entry(cwd, rel_path, max_bytes):
    """Returns the diff-text fragment (no leading newline) for one
    untracked file. Never dereferences a symlink, never blocks on a FIFO,
    never embeds NUL/binary content as text."""
    abs_path = os.path.join(cwd, rel_path)

    fd = None
    try:
        # O_NOFOLLOW: the open itself fails (ELOOP) if the final path
        # component is a symlink -- this PREVENTS a symlink swap between
        # any earlier check and this open outright, rather than detecting
        # one after the fact (the best bash could do without a portable
        # no-follow-open primitive). O_NONBLOCK: opening a FIFO with no
        # writer would otherwise block forever; this makes that open
        # return immediately instead.
        fd = os.open(abs_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as exc:
        if os.path.islink(abs_path):
            # Never dereference an untracked symlink -- reading through it
            # could leak the contents of an arbitrary file outside the repo
            # (e.g. a link pointing at ~/.ssh/id_rsa) into the prompt.
            try:
                target = os.readlink(abs_path)
            except OSError:
                target = "?"
            return f"--- new untracked file: {rel_path} (symlink -> {target}; target contents not read) ---"
        # Any other open failure (ENOENT -- vanished between listing and
        # open, EACCES, etc.) is reported the same way: safely unreadable,
        # never a crash.
        return f"--- new untracked file: {rel_path} (could not be safely read; contents omitted) ---"

    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            # Whitelist regular files only -- anything else (FIFO, device,
            # socket) that O_NOFOLLOW+O_NONBLOCK let through unopened-as-a-
            # symlink is rejected here instead of ever being read.
            return f"--- new untracked file: {rel_path} (not a regular file; contents not read) ---"
        if st.st_size > max_bytes:
            return f"--- new untracked file: {rel_path} (over 1MB cap or unreadable; contents omitted) ---"
        with os.fdopen(fd, "rb") as f:
            fd = None  # ownership transferred to the file object
            data = f.read(max_bytes + 1)
        if len(data) > max_bytes:
            # Grew between fstat and read (rare, e.g. a concurrent writer).
            return f"--- new untracked file: {rel_path} (over 1MB cap or unreadable; contents omitted) ---"
        if b"\x00" in data:
            # Matches how `git diff` itself represents a binary file (a
            # marker, not corrupted "text").
            return f"--- new untracked file: {rel_path} (binary content; not embedded as text) ---"
        text = data.decode("utf-8", errors="replace")
        return f"--- new untracked file: {rel_path} ---\n{text}"
    finally:
        if fd is not None:
            os.close(fd)


def collect(cwd, deadline_secs, max_bytes):
    """Returns (fragments, incomplete, error_detail)."""
    files, error_detail = list_untracked_files(cwd)
    if error_detail is not None:
        return [], False, error_detail

    fragments = []
    deadline = time.monotonic() + deadline_secs
    for rel_path in files:
        if time.monotonic() >= deadline:
            return fragments, True, None
        fragments.append(format_entry(cwd, rel_path, max_bytes))
    return fragments, False, None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("cwd")
    parser.add_argument("--deadline-secs", type=int, default=DEFAULT_DEADLINE_SECS)
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    args = parser.parse_args()

    fragments, incomplete, error_detail = collect(args.cwd, args.deadline_secs, args.max_bytes)
    if error_detail is not None:
        print(error_detail, file=sys.stderr)
        sys.exit(1)
    if incomplete:
        print(
            f"untracked-file collection exceeded its {args.deadline_secs}s aggregate budget; "
            "--uncommitted scope was not fully examined",
            file=sys.stderr,
        )
        sys.exit(2)
    for fragment in fragments:
        sys.stdout.write("\n" + fragment)
    sys.exit(0)


def _selftest():
    import tempfile

    failures = []

    def check(cond, msg):
        if not cond:
            failures.append(msg)

    # Case 1: real NUL byte -> binary marker, no corrupted content
    with tempfile.TemporaryDirectory() as proj:
        with open(os.path.join(proj, "bin.dat"), "wb") as f:
            f.write(b"left\x00right")
        out = format_entry(proj, "bin.dat", DEFAULT_MAX_BYTES)
        check("binary content; not embedded as text" in out, "binary case: wrong marker")
        check("leftright" not in out, "binary case: leaked corrupted content")

    # Case 2: plain text -> content embedded verbatim
    with tempfile.TemporaryDirectory() as proj:
        with open(os.path.join(proj, "plain.txt"), "w", encoding="utf-8") as f:
            f.write("hello from collect_untracked_files test")
        out = format_entry(proj, "plain.txt", DEFAULT_MAX_BYTES)
        check("hello from collect_untracked_files test" in out, "plain text case: content missing")

    # Case 3: symlink -> marker only, target never read (the original a4/c2
    # class of bug this design closes for good via O_NOFOLLOW)
    with tempfile.TemporaryDirectory() as proj, tempfile.TemporaryDirectory() as outside:
        with open(os.path.join(outside, "secret.txt"), "w", encoding="utf-8") as f:
            f.write("SECRET_VIA_SYMLINK")
        os.symlink(os.path.join(outside, "secret.txt"), os.path.join(proj, "link.txt"))
        out = format_entry(proj, "link.txt", DEFAULT_MAX_BYTES)
        check("symlink ->" in out and "target contents not read" in out, "symlink case: wrong marker")
        check("SECRET_VIA_SYMLINK" not in out, "symlink case: leaked target contents")

    # Case 4: oversized file -> capped before ever being read into memory
    with tempfile.TemporaryDirectory() as proj:
        with open(os.path.join(proj, "big.bin"), "wb") as f:
            f.write(b"\x00" * (DEFAULT_MAX_BYTES + 1000))
        out = format_entry(proj, "big.bin", DEFAULT_MAX_BYTES)
        check("over 1MB cap" in out, "oversize case: wrong marker")

    # Case 5: FIFO -> marker only, and MUST NOT block (O_NONBLOCK); wrapped
    # in a wall-clock guard so a future regression that makes this open
    # fails the test instead of hanging the whole selftest run.
    with tempfile.TemporaryDirectory() as proj:
        fifo_path = os.path.join(proj, "fifo_entry")
        os.mkfifo(fifo_path)
        start = time.monotonic()
        out = format_entry(proj, "fifo_entry", DEFAULT_MAX_BYTES)
        elapsed = time.monotonic() - start
        check("not a regular file" in out, "FIFO case: wrong marker")
        check(elapsed < 5, f"FIFO case: took {elapsed:.1f}s, should be instant (O_NONBLOCK regression)")

    # Case 6: vanished file (listed by git, deleted before we get to it) ->
    # graceful "could not be safely read", not a crash
    with tempfile.TemporaryDirectory() as proj:
        out = format_entry(proj, "does_not_exist.txt", DEFAULT_MAX_BYTES)
        check("could not be safely read" in out, "vanished-file case: wrong marker")

    # Case 7: real git integration -- list_untracked_files against a real repo
    with tempfile.TemporaryDirectory() as repo:
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=repo, check=True)
        with open(os.path.join(repo, "README.md"), "w", encoding="utf-8") as f:
            f.write("readme\n")
        subprocess.run(["git", "add", "README.md"], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=repo, check=True)
        with open(os.path.join(repo, "realfile.txt"), "w", encoding="utf-8") as f:
            f.write("content")
        files, error_detail = list_untracked_files(repo)
        check(error_detail is None, f"real repo case: unexpected error {error_detail}")
        check(files == ["realfile.txt"], f"real repo case: wrong file list {files}")

    # Case 8: deadline exceeded -> incomplete=True, real files not silently
    # skipped without a signal (the b4 regression class)
    with tempfile.TemporaryDirectory() as repo:
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=repo, check=True)
        with open(os.path.join(repo, "README.md"), "w", encoding="utf-8") as f:
            f.write("readme\n")
        subprocess.run(["git", "add", "README.md"], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=repo, check=True)
        with open(os.path.join(repo, "onlyfile.txt"), "w", encoding="utf-8") as f:
            f.write("content")
        fragments, incomplete, error_detail = collect(repo, deadline_secs=-1, max_bytes=DEFAULT_MAX_BYTES)
        check(incomplete is True, "deadline case: did not report incomplete")
        check(error_detail is None, f"deadline case: unexpected error {error_detail}")

    # Case 9: sufficient deadline -> file collected, not flagged incomplete
    with tempfile.TemporaryDirectory() as repo:
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=repo, check=True)
        with open(os.path.join(repo, "README.md"), "w", encoding="utf-8") as f:
            f.write("readme\n")
        subprocess.run(["git", "add", "README.md"], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=repo, check=True)
        with open(os.path.join(repo, "onlyfile.txt"), "w", encoding="utf-8") as f:
            f.write("content")
        fragments, incomplete, error_detail = collect(repo, deadline_secs=30, max_bytes=DEFAULT_MAX_BYTES)
        check(incomplete is False, "sufficient-deadline case: falsely reported incomplete")
        check(any("onlyfile.txt" in fr and "content" in fr for fr in fragments), "sufficient-deadline case: file not collected")

    if failures:
        for msg in failures:
            print(f"FAIL: {msg}", file=sys.stderr)
        print("collect_untracked_files.py: selftest FAILED", file=sys.stderr)
        sys.exit(1)
    print("collect_untracked_files.py: selftest OK")
    sys.exit(0)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()
