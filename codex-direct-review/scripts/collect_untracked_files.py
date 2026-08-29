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
safely killable on interrupt.

Design notes from /cc review of the first draft of this file (kept here so
the reasoning travels with the code):
- Every path is handled as BYTES end to end, never decoded to `str` for
  filesystem use. `errors="replace"` decoding is only ever applied to a
  COPY used for display text -- decoding a raw git-listed filename to
  `str` and then using THAT string to open the file (the first draft's
  bug) can silently open the wrong path, or none, for any filename that
  isn't valid UTF-8.
- File CONTENT is also never decoded/re-encoded. It is written to stdout
  as raw bytes. Decoding valid-but-non-UTF-8 NUL-free content with
  `errors="replace"` (the first draft's bug) silently corrupts it before
  Codex ever sees it -- worse than bash's original behavior, which just
  streamed bytes through untouched.
- Every path component is opened via a dir_fd-relative openat() chain,
  each with O_NOFOLLOW, starting from `cwd` (trusted, comes from the
  wrapper's own --cwd argument, not attacker-controlled). O_NOFOLLOW on
  a single whole-path open() only protects the FINAL component -- an
  earlier revision of this file used exactly that single-open form, and
  a TOCTOU swap of an INTERMEDIATE directory component (e.g. git lists
  `dir/file.txt`, `dir` is replaced with a symlink to an outside
  directory containing its own `file.txt` before the open) went
  completely undetected, silently reading and embedding the wrong file's
  content. Chaining opens closes this the same way the project's other
  Python file (session-resume-handoff.py) already closes the identical
  class of bug for its own path.
- A per-file SIGALRM-based read timeout (matching bash's original 3s
  per-file cap) bounds a single file's read, in addition to the aggregate
  deadline checked between files -- the aggregate check alone cannot stop
  a single pathologically slow read (e.g. a stalled network filesystem)
  from blocking past the whole collection's budget.

Usage: collect_untracked_files.py CWD [--deadline-secs N] [--max-bytes N]

Prints accumulated diff-text fragments to stdout AS RAW BYTES (each
prefixed by a newline, matching the bash wrapper's existing DIFF_TEXT
convention -- the prompt-building code downstream does not need to
change). Exit codes:
  0 -> success (collection completed, possibly with zero untracked files)
  1 -> fatal error (e.g. `git ls-files` failed) -- detail on stderr
  2 -> incomplete (the aggregate deadline was exceeded before every
       untracked file was examined) -- the CALLER must treat this as a hard
       failure, not proceed to a verdict on a partially-examined scope.
"""
import argparse
import errno
import os
import signal
import stat
import subprocess
import sys
import time

DEFAULT_DEADLINE_SECS = 30
DEFAULT_MAX_BYTES = 1024 * 1024
PER_FILE_TIMEOUT_SECS = 3


class _ReadTimeout(Exception):
    pass


def _alarm_handler(signum, frame):
    raise _ReadTimeout()


def read_with_timeout(f, max_bytes):
    """f.read(), bounded by a wall-clock SIGALRM in addition to whatever
    byte cap the caller passes -- protects against a single pathologically
    slow read (e.g. a stalled network filesystem) that the aggregate
    between-files deadline check alone cannot interrupt."""
    old_handler = signal.signal(signal.SIGALRM, _alarm_handler)
    signal.alarm(PER_FILE_TIMEOUT_SECS)
    try:
        return f.read(max_bytes + 1)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)


def list_untracked_files(cwd_bytes):
    """Returns (files_bytes, error_detail). error_detail is None on
    success. files_bytes is a list of raw path bytes -- NOT decoded, so
    filesystem operations on them can never diverge from what git actually
    listed.

    Uses subprocess.run with no shell involved -- argument-array exec, not
    a shell command string, so there is no injection risk and no way for
    stdout/stderr to be accidentally merged (the exact c1 bug this file's
    bash predecessor once had via `2>&1`)."""
    try:
        result = subprocess.run(
            ["git", "ls-files", "-z", "--others", "--exclude-standard"],
            cwd=cwd_bytes,
            capture_output=True,
            check=False,
        )
    except OSError as exc:
        return None, f"failed to run git: {exc}"
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        return None, f"failed to enumerate untracked files: {detail}"
    files = [f for f in result.stdout.split(b"\0") if f]
    return files, None


def open_nofollow_chain(cwd_bytes, rel_path_bytes):
    """Opens rel_path_bytes relative to cwd_bytes by walking each `/`
    -separated component through its own dir_fd-relative open() call, with
    O_NOFOLLOW (and O_DIRECTORY for every non-leaf component) at EVERY
    level -- not just the final one. Returns an open fd for the leaf (which
    may turn out to be non-regular; the caller fstats it), or raises
    OSError.

    A single `os.open(full_path, O_NOFOLLOW)` -- this function's
    predecessor -- only rejects a symlink in the FINAL component. If git
    lists `dir/file.txt` and `dir` itself gets swapped for a symlink to an
    outside directory (also containing a `file.txt`) between the listing
    and this open, that single-open form follows the swapped `dir` right
    through and happily reads the wrong file. Chaining closes this: each
    component is opened relative to the fd of the directory already
    confirmed one level up, so there is no path string left to re-resolve
    (and no window to swap) once a given level has been opened.
    """
    parts = rel_path_bytes.split(b"/")
    fd = os.open(cwd_bytes, os.O_RDONLY)
    for i, part in enumerate(parts):
        is_last = i == len(parts) - 1
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        if not is_last:
            flags |= os.O_DIRECTORY
        try:
            next_fd = os.open(part, flags, dir_fd=fd)
        finally:
            os.close(fd)
        fd = next_fd
    return fd


def format_entry(cwd_bytes, rel_path_bytes, max_bytes):
    """Returns a list of parts (each a `str` header/marker or raw `bytes`
    file content) for one untracked file -- never a single string, so file
    content never has to be decoded (and potentially corrupted) to be
    concatenated with the surrounding marker text. Never dereferences a
    symlink at any path component, never blocks on a FIFO, never embeds
    NUL/binary content as text, never silently rewrites non-UTF-8 content."""
    rel_display = rel_path_bytes.decode("utf-8", errors="replace")

    fd = None
    try:
        fd = open_nofollow_chain(cwd_bytes, rel_path_bytes)
    except OSError as exc:
        abs_path = os.path.join(cwd_bytes, rel_path_bytes)
        # A simple, common case -- the leaf itself is (still) a plain
        # symlink -- gets a specific, informative marker via a read-only
        # lstat-based check (this check does not open or read anything, so
        # it carries no TOCTOU risk of its own). Every other open failure,
        # INCLUDING an intermediate-component symlink swap (which this
        # check cannot and does not attempt to specifically diagnose,
        # since doing so would itself require walking the same path again)
        # gets the generic "unsafe/unreadable" marker -- the wording
        # differs, but the security property (content is never read) holds
        # either way.
        try:
            is_leaf_symlink = os.path.islink(abs_path)
        except OSError:
            is_leaf_symlink = False
        if is_leaf_symlink:
            try:
                target = os.readlink(abs_path).decode("utf-8", errors="replace")
            except OSError:
                target = "?"
            return [f"\n--- new untracked file: {rel_display} (symlink -> {target}; target contents not read) ---"]
        return [f"\n--- new untracked file: {rel_display} (could not be safely read; contents omitted) ---"]

    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            # Whitelist regular files only -- anything else (FIFO, device,
            # socket) that made it through the O_NOFOLLOW chain (i.e. was
            # never rejected as a symlink at any level) is rejected here
            # instead of ever being read.
            return [f"\n--- new untracked file: {rel_display} (not a regular file; contents not read) ---"]
        if st.st_size > max_bytes:
            return [f"\n--- new untracked file: {rel_display} (over 1MB cap or unreadable; contents omitted) ---"]
        with os.fdopen(fd, "rb") as f:
            fd = None  # ownership transferred to the file object
            try:
                data = read_with_timeout(f, max_bytes)
            except _ReadTimeout:
                return [f"\n--- new untracked file: {rel_display} (could not be safely read; contents omitted) ---"]
        if len(data) > max_bytes:
            # Grew between fstat and read (rare, e.g. a concurrent writer).
            return [f"\n--- new untracked file: {rel_display} (over 1MB cap or unreadable; contents omitted) ---"]
        if b"\x00" in data:
            # Matches how `git diff` itself represents a binary file (a
            # marker, not corrupted "text").
            return [f"\n--- new untracked file: {rel_display} (binary content; not embedded as text) ---"]
        # Raw bytes, never decoded -- valid-but-non-UTF-8 NUL-free content
        # (e.g. a legacy-encoded source file) is passed through byte for
        # byte instead of being silently rewritten with U+FFFD replacement
        # characters.
        return [f"\n--- new untracked file: {rel_display} ---\n", data]
    finally:
        if fd is not None:
            os.close(fd)


def collect(cwd_bytes, deadline_secs, max_bytes):
    """Returns (parts, incomplete, error_detail). parts is a flat list of
    str/bytes fragments, in the same mixed-type shape format_entry returns."""
    files, error_detail = list_untracked_files(cwd_bytes)
    if error_detail is not None:
        return [], False, error_detail

    parts = []
    deadline = time.monotonic() + deadline_secs
    for rel_path_bytes in files:
        if time.monotonic() >= deadline:
            return parts, True, None
        parts.extend(format_entry(cwd_bytes, rel_path_bytes, max_bytes))
    return parts, False, None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("cwd")
    parser.add_argument("--deadline-secs", type=int, default=DEFAULT_DEADLINE_SECS)
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    args = parser.parse_args()

    cwd_bytes = os.fsencode(args.cwd)
    parts, incomplete, error_detail = collect(cwd_bytes, args.deadline_secs, args.max_bytes)
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
    for part in parts:
        if isinstance(part, str):
            sys.stdout.buffer.write(part.encode("utf-8"))
        else:
            sys.stdout.buffer.write(part)
    sys.stdout.buffer.flush()
    sys.exit(0)


def _parts_to_text(parts):
    """Test helper: joins mixed str/bytes parts into one str for substring
    assertions (decoding any raw bytes with errors="replace" -- fine for a
    test assertion, unlike in the production code path)."""
    out = []
    for part in parts:
        out.append(part if isinstance(part, str) else part.decode("utf-8", errors="replace"))
    return "".join(out)


def _selftest():
    import tempfile

    failures = []

    def check(cond, msg):
        if not cond:
            failures.append(msg)

    def fmt(proj, rel_path, max_bytes=DEFAULT_MAX_BYTES):
        return _parts_to_text(format_entry(os.fsencode(proj), rel_path.encode("utf-8"), max_bytes))

    # Case 1: real NUL byte -> binary marker, no corrupted content
    with tempfile.TemporaryDirectory() as proj:
        with open(os.path.join(proj, "bin.dat"), "wb") as f:
            f.write(b"left\x00right")
        out = fmt(proj, "bin.dat")
        check("binary content; not embedded as text" in out, "binary case: wrong marker")
        check("leftright" not in out, "binary case: leaked corrupted content")

    # Case 2: plain text -> content embedded verbatim
    with tempfile.TemporaryDirectory() as proj:
        with open(os.path.join(proj, "plain.txt"), "w", encoding="utf-8") as f:
            f.write("hello from collect_untracked_files test")
        out = fmt(proj, "plain.txt")
        check("hello from collect_untracked_files test" in out, "plain text case: content missing")

    # Case 3: symlink -> marker only, target never read (the original a4/c2
    # class of bug this design closes for good via O_NOFOLLOW)
    with tempfile.TemporaryDirectory() as proj, tempfile.TemporaryDirectory() as outside:
        with open(os.path.join(outside, "secret.txt"), "w", encoding="utf-8") as f:
            f.write("SECRET_VIA_SYMLINK")
        os.symlink(os.path.join(outside, "secret.txt"), os.path.join(proj, "link.txt"))
        out = fmt(proj, "link.txt")
        check("symlink ->" in out and "target contents not read" in out, "symlink case: wrong marker")
        check("SECRET_VIA_SYMLINK" not in out, "symlink case: leaked target contents")

    # Case 4: oversized file -> capped before ever being read into memory
    with tempfile.TemporaryDirectory() as proj:
        with open(os.path.join(proj, "big.bin"), "wb") as f:
            f.write(b"\x00" * (DEFAULT_MAX_BYTES + 1000))
        out = fmt(proj, "big.bin")
        check("over 1MB cap" in out, "oversize case: wrong marker")

    # Case 5: FIFO -> marker only, and MUST NOT block (O_NONBLOCK); wrapped
    # in a wall-clock guard so a future regression that makes this open
    # fails the test instead of hanging the whole selftest run.
    with tempfile.TemporaryDirectory() as proj:
        fifo_path = os.path.join(proj, "fifo_entry")
        os.mkfifo(fifo_path)
        start = time.monotonic()
        out = fmt(proj, "fifo_entry")
        elapsed = time.monotonic() - start
        check("not a regular file" in out, "FIFO case: wrong marker")
        check(elapsed < 5, f"FIFO case: took {elapsed:.1f}s, should be instant (O_NONBLOCK regression)")

    # Case 6: vanished file (listed by git, deleted before we get to it) ->
    # graceful "could not be safely read", not a crash
    with tempfile.TemporaryDirectory() as proj:
        out = fmt(proj, "does_not_exist.txt")
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
        files, error_detail = list_untracked_files(os.fsencode(repo))
        check(error_detail is None, f"real repo case: unexpected error {error_detail}")
        check(files == [b"realfile.txt"], f"real repo case: wrong file list {files}")

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
        parts, incomplete, error_detail = collect(os.fsencode(repo), deadline_secs=-1, max_bytes=DEFAULT_MAX_BYTES)
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
        parts, incomplete, error_detail = collect(os.fsencode(repo), deadline_secs=30, max_bytes=DEFAULT_MAX_BYTES)
        out = _parts_to_text(parts)
        check(incomplete is False, "sufficient-deadline case: falsely reported incomplete")
        check("onlyfile.txt" in out and "content" in out, "sufficient-deadline case: file not collected")

    # Case 10: intermediate-directory symlink TOCTOU (the c1/high finding
    # this whole rewrite exists to close) -- git lists `dir/file.txt`, but
    # `dir` is ITSELF a symlink pointing outside the project, to a
    # directory that also happens to contain a `file.txt`. A single
    # whole-path O_NOFOLLOW open follows straight through `dir` and reads
    # the wrong (outside) file; the dir_fd chain must reject it instead.
    with tempfile.TemporaryDirectory() as proj, tempfile.TemporaryDirectory() as outside:
        os.makedirs(os.path.join(outside, "dir"))
        with open(os.path.join(outside, "dir", "file.txt"), "w", encoding="utf-8") as f:
            f.write("SECRET_VIA_INTERMEDIATE_SYMLINK")
        os.symlink(os.path.join(outside, "dir"), os.path.join(proj, "dir"))
        out = fmt(proj, "dir/file.txt")
        check("SECRET_VIA_INTERMEDIATE_SYMLINK" not in out, "intermediate-symlink case: leaked outside content")
        check("could not be safely read" in out, "intermediate-symlink case: wrong marker")

    # Case 11: valid-but-non-UTF-8, NUL-free content -> passed through byte
    # for byte, never corrupted via errors="replace" (the medium finding
    # from the first draft's review)
    with tempfile.TemporaryDirectory() as proj:
        with open(os.path.join(proj, "latin1.txt"), "wb") as f:
            f.write(b"alpha\xffomega")  # \xff is invalid UTF-8, has no NUL
        parts = format_entry(os.fsencode(proj), b"latin1.txt", DEFAULT_MAX_BYTES)
        raw_content_parts = [p for p in parts if isinstance(p, bytes)]
        check(len(raw_content_parts) == 1, "non-UTF-8 content case: expected exactly one raw bytes part")
        check(raw_content_parts and raw_content_parts[0] == b"alpha\xffomega", "non-UTF-8 content case: content was altered")

    # Case 12: non-UTF-8 filename -> still opened correctly via raw bytes
    # (the other medium finding: decoding the filename before using it as
    # a path can silently open the wrong file, or none). Skipped, with a
    # clear notice, on filesystems that refuse to create such a filename
    # in the first place (macOS APFS enforces valid Unicode filenames --
    # confirmed live, EILSEQ "Illegal byte sequence" -- so git could never
    # list one there either, making the scenario unreachable on this
    # platform specifically, not untested by choice).
    with tempfile.TemporaryDirectory() as proj:
        bad_name = b"bad-\xffname.txt"
        try:
            with open(os.path.join(os.fsencode(proj), bad_name), "wb") as f:
                f.write(b"content for the odd-named file")
        except OSError as exc:
            if exc.errno == errno.EILSEQ:
                print(
                    "SKIP: non-UTF-8 filename case -- this filesystem rejects such filenames outright (EILSEQ)",
                    file=sys.stderr,
                )
            else:
                raise
        else:
            out = _parts_to_text(format_entry(os.fsencode(proj), bad_name, DEFAULT_MAX_BYTES))
            check("content for the odd-named file" in out, "non-UTF-8 filename case: wrong file opened or not found")

    # Case 13: read_with_timeout actually bounds a slow read, tested
    # directly against a synthetic slow file-like object rather than
    # trying to force a real slow read through the filesystem. A FIFO
    # cannot be used for this: its fd is opened with O_NONBLOCK (needed so
    # opening one with no writer never blocks), and O_NONBLOCK makes reads
    # on it non-blocking too -- confirmed live, a read against a FIFO with
    # some data already written but not yet closed returns that data
    # immediately rather than blocking for more, so it can never exercise
    # this alarm at all. Patches PER_FILE_TIMEOUT_SECS via
    # `sys.modules[__name__]` (not a fresh `import`, which -- run this way,
    # as `__main__` -- would create a SEPARATE module object with its own
    # independent globals that read_with_timeout never actually reads from).
    class _SlowFile:
        def read(self, n):
            time.sleep(5)
            return b"should never be returned"

    this_module = sys.modules[__name__]
    original_timeout = this_module.PER_FILE_TIMEOUT_SECS
    this_module.PER_FILE_TIMEOUT_SECS = 1
    try:
        start = time.monotonic()
        try:
            read_with_timeout(_SlowFile(), DEFAULT_MAX_BYTES)
            check(False, "per-file timeout case: read_with_timeout did not raise on a slow read")
        except _ReadTimeout:
            pass
        elapsed = time.monotonic() - start
        check(
            elapsed < 3,
            f"per-file timeout case: took {elapsed:.1f}s, expected ~1s bound (PER_FILE_TIMEOUT_SECS regression)",
        )
    finally:
        this_module.PER_FILE_TIMEOUT_SECS = original_timeout

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
