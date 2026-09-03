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
import json
import os
import signal
import stat
import subprocess
import sys
import time

DEFAULT_DEADLINE_SECS = 30
DEFAULT_MAX_BYTES = 1024 * 1024
PER_FILE_TIMEOUT_SECS = 3

# Set by format_entry/_format_entry_body immediately before each of their
# returns (never derived by pattern-matching the marker TEXT they also
# return -- an earlier version of this file did exactly that, anchored on
# each marker's trailing "(<reason>) ---" suffix, and a /cc review round
# proved that unreliable two different ways: (1) an actual regular file
# whose OWN NAME happens to end in one of those exact reason phrases (e.g.
# a real, fully-included file literally named "ordinary (binary content;
# not embedded as text)") produces a normal-inclusion marker string that
# is byte-for-byte indistinguishable from a genuine omission marker by
# suffix alone, live-confirmed to misclassify it as omitted; (2) the
# regex's `.*` for a symlink target does not span an embedded newline in
# the target path without re.DOTALL, silently failing to classify that
# case at all. Both failure modes exist because the filename is untrusted,
# caller-controlled content concatenated into the very same string being
# pattern-matched -- no fixed suffix pattern can be made robust against a
# file deliberately or coincidentally named to end in it.  Reading this
# side-channel global instead is correct regardless of what any filename
# contains, because it is set directly by the CODE PATH that decided the
# outcome, never inferred from rendered text.
LAST_ENTRY_OMISSION_REASON = None


class _ReadTimeout(Exception):
    pass


def _alarm_handler(signum, frame):
    raise _ReadTimeout()


def run_with_timeout(func, *args, timeout_secs=PER_FILE_TIMEOUT_SECS, **kwargs):
    """Runs func(*args, **kwargs) under a SIGALRM-based wall-clock timeout
    covering the ENTIRE call. Raises _ReadTimeout if it fires before func
    returns.

    An earlier revision only wrapped the final `.read()` call this way,
    leaving the preceding open()/fstat() completely unbounded -- a stalled
    filesystem's metadata lookups can hang exactly like its data reads can,
    so the timeout needs to cover the whole per-file operation, not just
    the read at the end of it.

    The handler-install and the alarm arm/disarm are each in their OWN
    try/finally, nested, rather than one try starting only after both setup
    calls -- an earlier revision's `try` started after `signal.alarm(...)`,
    so an exception raised between installing the handler and entering the
    try (however unlikely) would skip the `finally` entirely, leaving the
    alarm armed (it would later fire and raise _ReadTimeout somewhere
    completely unrelated) and the old handler never restored."""
    old_handler = signal.signal(signal.SIGALRM, _alarm_handler)
    try:
        signal.alarm(timeout_secs)
        try:
            return func(*args, **kwargs)
        finally:
            signal.alarm(0)
    finally:
        signal.signal(signal.SIGALRM, old_handler)


def list_untracked_files(cwd_bytes, timeout_secs):
    """Returns (files_bytes, error_detail). error_detail is None on
    success. files_bytes is a list of raw path bytes -- NOT decoded, so
    filesystem operations on them can never diverge from what git actually
    listed.

    Uses subprocess.run with no shell involved -- argument-array exec, not
    a shell command string, so there is no injection risk and no way for
    stdout/stderr to be accidentally merged (the exact c1 bug this file's
    bash predecessor once had via `2>&1`). Bounded by `timeout_secs` (the
    caller's aggregate deadline) -- an earlier revision had no timeout at
    all here, so a stalled `git ls-files` (e.g. a lock file, a pathological
    repo state) could hang the entire collection indefinitely, before the
    deadline-tracking loop even started. subprocess.run's own timeout
    handling kills the child process itself on expiry, so a timed-out git
    process is not left running either."""
    try:
        result = subprocess.run(
            ["git", "ls-files", "-z", "--others", "--exclude-standard"],
            cwd=cwd_bytes,
            capture_output=True,
            check=False,
            timeout=timeout_secs,
        )
    except subprocess.TimeoutExpired:
        return None, f"git ls-files did not complete within {timeout_secs}s"
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
        # Two failure points, each needing its own cleanup target: if
        # os.open itself fails, only `fd` (the parent, still open) needs
        # closing -- `next_fd` was never created. If os.open SUCCEEDS but
        # the subsequent close of the old `fd` then fails (rare, but
        # os.close is not guaranteed to succeed), `next_fd` is a live,
        # newly-opened descriptor with no other reference anywhere -- an
        # earlier revision's single `try/finally: os.close(fd)` around just
        # the open call left exactly this second case leaking `next_fd`.
        #
        # `except BaseException` (not just OSError) at both points: this
        # chain runs inside run_with_timeout's SIGALRM window when called
        # from format_entry, and a timeout firing WHILE blocked inside one
        # of these os.open() calls raises _ReadTimeout (not an OSError) at
        # that exact point -- narrower exception handling here would skip
        # the fd cleanup entirely on that path and leak it.
        try:
            next_fd = os.open(part, flags, dir_fd=fd)
        except BaseException:
            os.close(fd)
            raise
        try:
            os.close(fd)
        except BaseException:
            os.close(next_fd)
            raise
        fd = next_fd
    return fd


def format_entry(cwd_bytes, rel_path_bytes, max_bytes):
    """Returns a list of parts (each a `str` header/marker or raw `bytes`
    file content) for one untracked file -- never a single string, so file
    content never has to be decoded (and potentially corrupted) to be
    concatenated with the surrounding marker text. Never dereferences a
    symlink at any path component, never blocks on a FIFO, never embeds
    NUL/binary content as text, never silently rewrites non-UTF-8 content.

    The entire body runs under run_with_timeout -- an earlier revision only
    wrapped the final read() call, leaving the preceding open()/fstat()
    completely unbounded. A stalled filesystem (e.g. a hung network mount)
    can make the OPEN or the metadata lookup hang just as easily as the
    data read, and this must be bounded the same way either can."""
    rel_display = rel_path_bytes.decode("utf-8", errors="replace")
    try:
        return run_with_timeout(_format_entry_body, cwd_bytes, rel_path_bytes, rel_display, max_bytes)
    except _ReadTimeout:
        # _format_entry_body was interrupted mid-execution -- whatever it
        # last set LAST_ENTRY_OMISSION_REASON to is not trustworthy (it may
        # not have reached any return site at all), so this is set
        # explicitly here rather than relying on whatever state the
        # interrupted call left behind.
        global LAST_ENTRY_OMISSION_REASON
        LAST_ENTRY_OMISSION_REASON = "unreadable"
        return [f"\n--- new untracked file: {rel_display} (could not be safely read; contents omitted) ---"]


def _format_entry_body(cwd_bytes, rel_path_bytes, rel_display, max_bytes):
    global LAST_ENTRY_OMISSION_REASON
    # Reset at the top of every call, before any return path -- every
    # return below sets this explicitly anyway, but resetting here too
    # means a future return site that forgets to set it fails safe (stays
    # "unreadable"-like/omitted, the conservative direction) rather than
    # silently inheriting the PREVIOUS file's classification.
    LAST_ENTRY_OMISSION_REASON = "unreadable"
    fd = None
    try:
        fd = open_nofollow_chain(cwd_bytes, rel_path_bytes)
    except OSError:
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
            LAST_ENTRY_OMISSION_REASON = "symlink"
            return [f"\n--- new untracked file: {rel_display} (symlink -> {target}; target contents not read) ---"]
        LAST_ENTRY_OMISSION_REASON = "unreadable"
        return [f"\n--- new untracked file: {rel_display} (could not be safely read; contents omitted) ---"]

    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            # Whitelist regular files only -- anything else (FIFO, device,
            # socket) that made it through the O_NOFOLLOW chain (i.e. was
            # never rejected as a symlink at any level) is rejected here
            # instead of ever being read.
            LAST_ENTRY_OMISSION_REASON = "not_regular_file"
            return [f"\n--- new untracked file: {rel_display} (not a regular file; contents not read) ---"]
        if st.st_size > max_bytes:
            LAST_ENTRY_OMISSION_REASON = "over_size_limit"
            return [f"\n--- new untracked file: {rel_display} (over 1MB cap or unreadable; contents omitted) ---"]
        with os.fdopen(fd, "rb") as f:
            fd = None  # ownership transferred to the file object
            data = f.read(max_bytes + 1)
        if len(data) > max_bytes:
            # Grew between fstat and read (rare, e.g. a concurrent writer).
            LAST_ENTRY_OMISSION_REASON = "over_size_limit"
            return [f"\n--- new untracked file: {rel_display} (over 1MB cap or unreadable; contents omitted) ---"]
        if b"\x00" in data:
            # Matches how `git diff` itself represents a binary file (a
            # marker, not corrupted "text").
            LAST_ENTRY_OMISSION_REASON = "binary"
            return [f"\n--- new untracked file: {rel_display} (binary content; not embedded as text) ---"]
        # Raw bytes, never decoded -- valid-but-non-UTF-8 NUL-free content
        # (e.g. a legacy-encoded source file) is passed through byte for
        # byte instead of being silently rewritten with U+FFFD replacement
        # characters.
        LAST_ENTRY_OMISSION_REASON = None
        return [f"\n--- new untracked file: {rel_display} ---\n", data]
    finally:
        if fd is not None:
            os.close(fd)


def _empty_coverage():
    return {"reviewed_file_count": 0, "omitted": []}


def collect(cwd_bytes, deadline_secs, max_bytes):
    """Returns (parts, incomplete, error_detail, coverage). parts is a flat
    list of str/bytes fragments, in the same mixed-type shape format_entry
    returns. coverage is {"reviewed_file_count": <int>, "omitted":
    [{"path": <str>, "reason": <str>}, ...]} -- one "omitted" entry per
    untracked file whose content was NOT included (reason vocabulary: see
    LAST_ENTRY_OMISSION_REASON's set sites in _format_entry_body/
    format_entry); reviewed_file_count counts every OTHER untracked file
    (content fully included). Always the zero-value shape from
    _empty_coverage() when error_detail is not None (collection never got
    far enough to process any file).

    `deadline` is computed ONCE, here, before `git ls-files` even runs, and
    the TIME REMAINING against that single deadline is what bounds the git
    call -- not a fresh `deadline_secs`-sized budget of its own. An earlier
    revision computed the per-file-loop deadline only after `git ls-files`
    returned, which gave git an ADDITIONAL, separate `deadline_secs` on top
    of whatever the loop later got -- silently doubling the true aggregate
    budget this function is documented to enforce."""
    deadline = time.monotonic() + deadline_secs
    remaining = max(0, deadline - time.monotonic())
    files, error_detail = list_untracked_files(cwd_bytes, remaining)
    if error_detail is not None:
        return [], False, error_detail, _empty_coverage()

    parts = []
    coverage = _empty_coverage()
    for rel_path_bytes in files:
        if time.monotonic() >= deadline:
            return parts, True, None, coverage
        entry_parts = format_entry(cwd_bytes, rel_path_bytes, max_bytes)
        # Read the side-channel global format_entry/_format_entry_body just
        # set (see LAST_ENTRY_OMISSION_REASON's own comment for why this,
        # not text-parsing entry_parts, is the only reliable way to learn
        # the outcome) -- captured immediately, before anything else can
        # run and potentially change it.
        reason = LAST_ENTRY_OMISSION_REASON
        if reason is not None:
            coverage["omitted"].append({"path": rel_path_bytes.decode("utf-8", errors="replace"), "reason": reason})
        else:
            coverage["reviewed_file_count"] += 1
        parts.extend(entry_parts)
    # The deadline check above only gates whether a file's processing
    # STARTS within budget -- a single file's own read can still take up
    # to PER_FILE_TIMEOUT_SECS, which can push the loop's total elapsed
    # time past `deadline` even though every per-file check passed. Check
    # once more after the loop finishes normally, so "incomplete" reflects
    # whether the WHOLE collection finished within its aggregate budget,
    # not just whether every file happened to start in time.
    if time.monotonic() >= deadline:
        return parts, True, None, coverage
    return parts, False, None, coverage


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("cwd")
    parser.add_argument("--deadline-secs", type=int, default=DEFAULT_DEADLINE_SECS)
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    parser.add_argument(
        "--coverage-out",
        default=None,
        help="optional path to write a JSON {reviewed_file_count, omitted} summary to, "
        "for the caller to surface as wrapper-owned coverage metadata -- never written "
        "on a hard failure (exit 1/2), since there is nothing truthful to report then.",
    )
    args = parser.parse_args()

    cwd_bytes = os.fsencode(args.cwd)
    parts, incomplete, error_detail, coverage = collect(cwd_bytes, args.deadline_secs, args.max_bytes)
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
    if args.coverage_out is not None:
        # A live review of this very change caught that an unhandled write
        # failure here (confirmed with a real OSError writing to /dev/full)
        # crashes this whole process with an uncaught traceback, which the
        # wrapper's own exit-code handling maps to a hard `git_error` --
        # discarding an otherwise fully successful collection (the real
        # diff/untracked content in `parts` below, already gathered)
        # entirely just because this OPTIONAL diagnostic sidecar could not
        # be written. This is exactly the failure this feature's own
        # design intends to tolerate (the wrapper's own coverage-file READ
        # already degrades gracefully to "no coverage metadata" on a
        # missing/malformed file) -- it was only ever handled on the READ
        # side, not here on the WRITE side where the actual crash occurs.
        # Best-effort: on any failure, skip writing coverage entirely and
        # continue with the real content below rather than losing it.
        try:
            with open(args.coverage_out, "w", encoding="utf-8") as f:
                json.dump(coverage, f)
        except OSError as exc:
            print(f"warning: failed to write --coverage-out ({exc}); continuing without it", file=sys.stderr)
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
    import shutil
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
        check(LAST_ENTRY_OMISSION_REASON == "binary", f"binary case: coverage reason wrong: {LAST_ENTRY_OMISSION_REASON!r}")

    # Case 2: plain text -> content embedded verbatim
    with tempfile.TemporaryDirectory() as proj:
        with open(os.path.join(proj, "plain.txt"), "w", encoding="utf-8") as f:
            f.write("hello from collect_untracked_files test")
        out = fmt(proj, "plain.txt")
        check("hello from collect_untracked_files test" in out, "plain text case: content missing")
        check(LAST_ENTRY_OMISSION_REASON is None, f"plain text case: fully-included file wrongly marked omitted: {LAST_ENTRY_OMISSION_REASON!r}")

    # Case 2b: a fully-included file whose OWN NAME happens to end in an
    # omission-marker phrase must NOT be misclassified as omitted -- an
    # earlier revision derived the coverage reason by pattern-matching the
    # rendered marker TEXT (which embeds the filename), and a /cc review
    # round proved that unreliable: live-confirmed a real, fully-included
    # file literally named to end in "(binary content; not embedded as
    # text)" produced a marker string indistinguishable-by-suffix from a
    # genuine omission. Reading LAST_ENTRY_OMISSION_REASON instead is
    # correct regardless of the filename, since it is set by the CODE PATH
    # taken, never inferred from rendered text.
    with tempfile.TemporaryDirectory() as proj:
        tricky_name = "ordinary (binary content; not embedded as text)"
        with open(os.path.join(proj, tricky_name), "w", encoding="utf-8") as f:
            f.write("small content, well under the cap, not binary at all")
        out = fmt(proj, tricky_name)
        check("small content, well under the cap" in out, "marker-lookalike-filename case: content missing")
        check(
            LAST_ENTRY_OMISSION_REASON is None,
            f"marker-lookalike-filename case: fully-included file misclassified as omitted: {LAST_ENTRY_OMISSION_REASON!r}",
        )

    # Case 3: symlink -> marker only, target never read (the original a4/c2
    # class of bug this design closes for good via O_NOFOLLOW)
    with tempfile.TemporaryDirectory() as proj, tempfile.TemporaryDirectory() as outside:
        with open(os.path.join(outside, "secret.txt"), "w", encoding="utf-8") as f:
            f.write("SECRET_VIA_SYMLINK")
        os.symlink(os.path.join(outside, "secret.txt"), os.path.join(proj, "link.txt"))
        out = fmt(proj, "link.txt")
        check("symlink ->" in out and "target contents not read" in out, "symlink case: wrong marker")
        check("SECRET_VIA_SYMLINK" not in out, "symlink case: leaked target contents")
        check(LAST_ENTRY_OMISSION_REASON == "symlink", f"symlink case: coverage reason wrong: {LAST_ENTRY_OMISSION_REASON!r}")

    # Case 4: oversized file -> capped before ever being read into memory
    with tempfile.TemporaryDirectory() as proj:
        with open(os.path.join(proj, "big.bin"), "wb") as f:
            f.write(b"\x00" * (DEFAULT_MAX_BYTES + 1000))
        out = fmt(proj, "big.bin")
        check("over 1MB cap" in out, "oversize case: wrong marker")
        check(
            LAST_ENTRY_OMISSION_REASON == "over_size_limit",
            f"oversize case: coverage reason wrong: {LAST_ENTRY_OMISSION_REASON!r}",
        )

    # Case 5: FIFO -> marker only, and MUST NOT block (O_NONBLOCK). Wrapped
    # in an ACTUALLY ENFORCED wall-clock guard via signal.alarm (matching
    # this project's session-resume-handoff.py, which uses the identical
    # technique for the identical reason) -- an earlier revision only
    # measured elapsed time AFTER the call returned, which is not a guard
    # at all: if a future regression made the open block forever, that
    # version would hang the whole selftest suite indefinitely instead of
    # failing after a bounded wait.
    with tempfile.TemporaryDirectory() as proj:
        fifo_path = os.path.join(proj, "fifo_entry")
        os.mkfifo(fifo_path)

        def _fifo_hang_handler(signum, frame):
            raise TimeoutError("format_entry blocked on a FIFO open -- O_NONBLOCK regression")

        old_handler = signal.signal(signal.SIGALRM, _fifo_hang_handler)
        signal.alarm(5)
        try:
            start = time.monotonic()
            out = fmt(proj, "fifo_entry")
            elapsed = time.monotonic() - start
        except TimeoutError as exc:
            check(False, str(exc))
        else:
            check("not a regular file" in out, "FIFO case: wrong marker")
            check(elapsed < 5, f"FIFO case: took {elapsed:.1f}s, should be near-instant")
            check(
                LAST_ENTRY_OMISSION_REASON == "not_regular_file",
                f"FIFO case: coverage reason wrong: {LAST_ENTRY_OMISSION_REASON!r}",
            )
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, old_handler)

    # Case 6: vanished file (listed by git, deleted before we get to it) ->
    # graceful "could not be safely read", not a crash
    with tempfile.TemporaryDirectory() as proj:
        out = fmt(proj, "does_not_exist.txt")
        check("could not be safely read" in out, "vanished-file case: wrong marker")
        check(
            LAST_ENTRY_OMISSION_REASON == "unreadable",
            f"vanished-file case: coverage reason wrong: {LAST_ENTRY_OMISSION_REASON!r}",
        )

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
        files, error_detail = list_untracked_files(os.fsencode(repo), DEFAULT_DEADLINE_SECS)
        check(error_detail is None, f"real repo case: unexpected error {error_detail}")
        check(files == [b"realfile.txt"], f"real repo case: wrong file list {files}")

    # Case 7b: git ls-files itself is bounded by the aggregate deadline --
    # an earlier revision had no timeout on this subprocess call at all, so
    # a hung git process (e.g. a lock file, a pathological repo state)
    # could block the entire collection indefinitely before the
    # deadline-tracking loop even started.
    with tempfile.TemporaryDirectory() as repo:
        files, error_detail = list_untracked_files(os.fsencode(repo), timeout_secs=0)
        check(files is None, "git-timeout case: expected no file list on timeout")
        check(
            error_detail is not None and "did not complete" in error_detail,
            f"git-timeout case: wrong error detail {error_detail!r}",
        )

    # Case 8: an already-past deadline (before git even runs) never
    # silently succeeds -- real files are not silently skipped without ANY
    # signal (the b4 regression class). Since `collect` now computes ONE
    # deadline up front and gives git ls-files only the time REMAINING
    # against it (see collect's own comment on why -- an earlier revision
    # gave git a full separate deadline_secs budget of its own, silently
    # doubling the true aggregate), an already-negative deadline means git
    # itself gets essentially zero time and fails fast with error_detail
    # set, rather than reaching the per-file loop at all. Either way
    # (error_detail set, or incomplete=True) is an acceptable, honest
    # signal that examination did not complete -- what matters is that it
    # is never silently False/None on both.
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
        parts, incomplete, error_detail, _coverage = collect(os.fsencode(repo), deadline_secs=-1, max_bytes=DEFAULT_MAX_BYTES)
        check(
            incomplete is True or error_detail is not None,
            f"deadline case: silently succeeded (incomplete={incomplete}, error_detail={error_detail!r}) with a real untracked file present",
        )

    # Case 8b: the aggregate deadline is ALSO checked after the loop
    # finishes, not just before each file starts -- a single file's own
    # processing time can push total elapsed time past the deadline even
    # though every per-file pre-check passed (the medium finding from
    # round 3's review). Verified by monkey-patching format_entry (via
    # sys.modules[__name__], same technique as the PER_FILE_TIMEOUT_SECS
    # patch above -- a fresh `import` here would hit the same separate-
    # module-object trap) to simulate a file whose processing alone
    # exceeds a very short deadline.
    this_module = sys.modules[__name__]
    original_format_entry = this_module.format_entry

    def _slow_format_entry(cwd_bytes, rel_path_bytes, max_bytes):
        time.sleep(0.2)
        return ["\n--- new untracked file: slow (simulated) ---"]

    this_module.format_entry = _slow_format_entry
    try:
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
            # 0.1s passes the PRE-file check (the loop has barely started),
            # but the single (patched, 0.2s) file read alone exceeds it.
            parts, incomplete, error_detail, _coverage = collect(os.fsencode(repo), deadline_secs=0.1, max_bytes=DEFAULT_MAX_BYTES)
            check(
                incomplete is True,
                "post-loop deadline case: did not report incomplete when the last file's own processing exceeded the aggregate budget",
            )
    finally:
        this_module.format_entry = original_format_entry

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
        parts, incomplete, error_detail, coverage = collect(os.fsencode(repo), deadline_secs=30, max_bytes=DEFAULT_MAX_BYTES)
        out = _parts_to_text(parts)
        check(incomplete is False, "sufficient-deadline case: falsely reported incomplete")
        check("onlyfile.txt" in out and "content" in out, "sufficient-deadline case: file not collected")
        check(
            coverage == {"reviewed_file_count": 1, "omitted": []},
            f"sufficient-deadline case: coverage wrong for one fully-included file: {coverage!r}",
        )

    # Case 9b: end-to-end through collect() (not just format_entry directly,
    # unlike Case 2b above) -- a fully-included file whose NAME happens to
    # contain a reason phrase must still come out of the FULL collection
    # pipeline correctly classified via LAST_ENTRY_OMISSION_REASON, not
    # just in isolation.
    with tempfile.TemporaryDirectory() as repo:
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=repo, check=True)
        with open(os.path.join(repo, "README.md"), "w", encoding="utf-8") as f:
            f.write("readme\n")
        subprocess.run(["git", "add", "README.md"], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=repo, check=True)
        tricky_name = "over 1MB cap or unreadable; contents omitted.txt"
        with open(os.path.join(repo, tricky_name), "w", encoding="utf-8") as f:
            f.write("small content, well under the cap")
        parts, incomplete, error_detail, coverage = collect(os.fsencode(repo), deadline_secs=30, max_bytes=DEFAULT_MAX_BYTES)
        check(
            coverage == {"reviewed_file_count": 1, "omitted": []},
            f"marker-lookalike-filename case: a fully-included file was misclassified as omitted: {coverage!r}",
        )

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

    # Case 10b: the same attack, but as a GENUINE concurrent race rather
    # than a pre-existing symlink -- a child process repeatedly swaps
    # `proj/dir` between a real directory (harmless decoy content) and a
    # symlink to the outside secret, while the parent repeatedly reads
    # `dir/file.txt`. Case 10 alone only proves the code rejects an
    # ALREADY-symlinked path; it does not exercise a live swap, so it would
    # also pass a flawed check-then-open implementation that is vulnerable
    # to a swap happening strictly between its own check and its own open.
    # This case proves the ATOMIC per-component open (no separate check
    # step for intermediate directories at all, unlike bash's original
    # design, which had no dir_fd primitive and HAD to check-then-open)
    # actually holds under real concurrent swapping, not just against a
    # static fixture.
    #
    # The child reports back how many swaps it actually performed (via a
    # plain file, written once at the end -- not a live handshake, but
    # enough to prove the race was meaningfully exercised) and its exit
    # status is checked, so a "no leak" result cannot come from a child
    # that crashed immediately or somehow performed zero swaps -- a real
    # gap Codex found in an earlier revision of this exact test (it
    # suppressed every child-side OSError and never checked the child's
    # outcome at all, so a "no leak" could trivially mean "the race never
    # actually happened").
    with tempfile.TemporaryDirectory() as proj, tempfile.TemporaryDirectory() as outside:
        os.makedirs(os.path.join(outside, "dir"))
        with open(os.path.join(outside, "dir", "file.txt"), "w", encoding="utf-8") as f:
            f.write("SECRET_VIA_RACE")
        proj_dir_path = os.path.join(proj, "dir")
        outside_target = os.path.join(outside, "dir")
        swap_count_path = os.path.join(proj, ".swap_count")

        pid = os.fork()
        if pid == 0:
            end = time.monotonic() + 1.0
            toggle = 0
            swaps = 0
            while time.monotonic() < end:
                try:
                    if os.path.islink(proj_dir_path):
                        os.unlink(proj_dir_path)
                    elif os.path.exists(proj_dir_path):
                        shutil.rmtree(proj_dir_path)
                    if toggle % 2 == 0:
                        os.makedirs(proj_dir_path)
                        with open(os.path.join(proj_dir_path, "file.txt"), "w", encoding="utf-8") as f:
                            f.write("decoy")
                    else:
                        os.symlink(outside_target, proj_dir_path)
                    swaps += 1
                except OSError:
                    pass
                toggle += 1
            try:
                with open(swap_count_path, "w", encoding="utf-8") as f:
                    f.write(str(swaps))
            except OSError:
                pass
            os._exit(0)

        try:
            leaked = False
            end = time.monotonic() + 1.0
            while time.monotonic() < end:
                out = fmt(proj, "dir/file.txt")
                if "SECRET_VIA_RACE" in out:
                    leaked = True
                    break
            check(not leaked, "intermediate-symlink RACE case: secret leaked under genuine concurrent directory swapping")
        finally:
            _, wait_status = os.waitpid(pid, 0)
            check(
                os.WIFEXITED(wait_status) and os.WEXITSTATUS(wait_status) == 0,
                f"intermediate-symlink RACE case: child did not exit cleanly (wait status {wait_status})",
            )

        try:
            with open(swap_count_path, "r", encoding="utf-8") as f:
                swap_count = int(f.read().strip())
        except (OSError, ValueError):
            swap_count = 0
        # A conservative floor (not e.g. 100+) so this stays reliable on a
        # slow/loaded machine -- each swap is only a few syscalls, so even
        # under heavy contention, ten full swaps in a whole second would be
        # an extreme, most-likely-broken slowdown, not normal variance.
        check(
            swap_count > 10,
            f"intermediate-symlink RACE case: child only performed {swap_count} swaps -- race was not meaningfully exercised",
        )

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

    # Case 13: run_with_timeout actually bounds a slow call, tested
    # directly against a synthetic slow function rather than trying to
    # force a real slow read through the filesystem. A FIFO cannot be used
    # for this: its fd is opened with O_NONBLOCK (needed so opening one
    # with no writer never blocks), and O_NONBLOCK makes reads on it
    # non-blocking too -- confirmed live, a read against a FIFO with some
    # data already written but not yet closed returns that data
    # immediately rather than blocking for more, so it can never exercise
    # this alarm at all. Uses an explicit `timeout_secs=1` argument rather
    # than patching PER_FILE_TIMEOUT_SECS (run_with_timeout takes the
    # timeout directly; only format_entry defaults to the module constant).
    def _slow_call():
        time.sleep(5)
        return "should never be returned"

    start = time.monotonic()
    try:
        run_with_timeout(_slow_call, timeout_secs=1)
        check(False, "per-file timeout case: run_with_timeout did not raise on a slow call")
    except _ReadTimeout:
        pass
    elapsed = time.monotonic() - start
    check(
        elapsed < 3,
        f"per-file timeout case: took {elapsed:.1f}s, expected ~1s bound",
    )

    # Case 14: a --coverage-out write failure must NOT crash the whole
    # process -- a live review of this exact feature (a real Codex CLI run,
    # not a synthetic test) caught that an earlier version let an uncaught
    # OSError from this write propagate and kill the process with a
    # traceback, which the wrapper's own exit-code handling maps to a hard
    # git_error -- discarding an otherwise fully successful collection
    # (real, already-gathered file content) entirely just because this
    # OPTIONAL diagnostic sidecar could not be written. Exercised via an
    # actual subprocess invocation of this script (not a direct function
    # call), since that boundary -- argparse, main()'s own sys.exit calls --
    # is exactly what the live review's reproduction went through and what
    # a direct call to collect()/main() in-process would not exercise the
    # same way. A directory path is used as --coverage-out's target (opening
    # a directory for writing raises IsADirectoryError, a portable, always-
    # reproducible OSError, unlike a platform-specific device like
    # /dev/full).
    with tempfile.TemporaryDirectory() as proj:
        subprocess.run(["git", "init", "-q"], cwd=proj, check=True)
        subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=proj, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=proj, check=True)
        with open(os.path.join(proj, "normal.txt"), "w", encoding="utf-8") as f:
            f.write("this content must still reach stdout")
        result = subprocess.run(
            [sys.executable, __file__, proj, "--coverage-out", proj],
            capture_output=True,
            timeout=10,
        )
        check(
            result.returncode == 0,
            f"coverage-out write-failure case: process exited {result.returncode}, expected 0 (degrade, don't crash); stderr={result.stderr!r}",
        )
        check(
            b"this content must still reach stdout" in result.stdout,
            f"coverage-out write-failure case: real file content missing from stdout: {result.stdout!r}",
        )

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
