# Non-repo-artifact review — reference

> Read this file in full because Phase 0 step 4 determined the material to review is not a repo
> diff at all (a pasted plan, generated text, or analysis text with no git diff to point to).

     **Why a non-repo-artifact round must NOT dispatch against `$REPO_ROOT`.** Dispatching
     `--uncommitted --cwd "$REPO_ROOT"` for a non-repo artifact points the wrapper at the user's
     real working tree — if that tree has ANY unrelated uncommitted changes, the wrapper reviews
     the ACTUAL DIFF whenever it is non-empty, using `--focus` only as context for it; it does
     NOT fall back to a focus-only review unless the diff is genuinely empty. So an artifact-only
     review dispatched against `$REPO_ROOT` would silently ALSO review those unrelated changes,
     contaminating findings and coverage with material the user never asked to review.

     **The fix:** the first time this session determines a round is a genuine non-repo-artifact
     review, create a throwaway clean git repo once and reuse it for every round of that same
     session — never recreate it per round:
     ```bash
     FAKE_GIT_HOME=$(mktemp -d "/tmp/ccs-${SESSION_ID}-fake-git-home.XXXXXX")
     CLEAN_REPO_DIR=$(mktemp -d "/tmp/ccs-${SESSION_ID}-artifact-repo.XXXXXX")
     env -i "PATH=$PATH" "HOME=$FAKE_GIT_HOME" "GIT_CONFIG_NOSYSTEM=1" \
       git -C "$CLEAN_REPO_DIR" init -q
     echo "CLEAN_REPO_DIR=$CLEAN_REPO_DIR"
     echo "FAKE_GIT_HOME=$FAKE_GIT_HOME"
     ```
     **This is an ALLOWLIST, not a denylist — deliberately: a denylist enumeration approach was
     tried here first and repeatedly bypassed.** `git`'s own repository/worktree discovery honors
     several environment variables OVER `-C`/`cd` (confirmed directly), and each successive
     hand-picked-then-dynamically-queried unset list was defeated by another variable or by a
     bootstrap failure in the query itself — a denylist cannot converge on "every variable,
     including ones that can break the very discovery mechanism used to build the list." `env -i`
     sidesteps this entirely by clearing the ENTIRE environment unconditionally and re-admitting
     only `PATH` (to find the `git` binary at all), a dedicated `FAKE_GIT_HOME` (so no real or
     attacker-controlled `HOME` can supply a `.gitconfig`), and `GIT_CONFIG_NOSYSTEM=1` (so
     `/etc/gitconfig` is never read) — the same `env -i` allowlist pattern this project's own
     git-isolation code already uses elsewhere (see `scripts/lib/git-safe.sh`'s `git_safe()`
     helper, referenced again below).

     `FAKE_GIT_HOME` is session-scoped exactly like `CLEAN_REPO_DIR` — allocated once, lazily, the
     first time this session needs it, remembered as an exact literal for the rest of the run, and
     cleaned up in Phase 3 alongside `CLEAN_REPO_DIR` (`rm -rf`, not just `CLEAN_REPO_DIR`'s own
     cleanup — see Phase 3 below). It must be a genuinely SEPARATE directory from `CLEAN_REPO_DIR`
     itself (never reuse one for the other) — `HOME` and the git worktree being initialized are
     different concerns, and collapsing them risks `git init` writing `.gitconfig`-adjacent state
     into the same directory whose content is supposed to be exactly what `CLEAN_REPO_DIR` isolates.

     **Two separate isolation mechanisms exist for two separate call sites — keep them distinct.**
     The allowlist above protects Claude's own pre-flight `git init` call for `CLEAN_REPO_DIR`.
     Every round's actual review dispatch (Phase 1 Step 1 below) invokes `run-ccs-review.sh`, a
     different call site with its own, separate isolation: the wrapper sources
     `scripts/lib/git-safe.sh` and routes all of its internal git calls (diff/show/rev-parse/
     hash-object) through its `git_safe()` helper — a pre-resolved, absolute `git` binary run under
     `env -i` with a fixed `PATH`, an isolated `HOME`, `GIT_CONFIG_NOSYSTEM=1`, `-C "$CWD"` (never a
     bare `cd`), and `-c core.fsmonitor=` to close the repo-local-config execution gap an
     environment-only allowlist can't reach on its own. See `scripts/lib/git-safe.sh` for the full
     mechanism and rationale — the two-front gap this paragraph used to describe (no wrapper-side
     isolation, plus an uncovered `core.fsmonitor` execution path) is closed; nothing further is
     needed at the SKILL.md layer for this call site.

     That's otherwise the whole setup — no seed file, no `git add`, no `git commit`. `CLEAN_REPO_DIR` is
     left exactly as `git init -q` leaves it: an unborn-HEAD repository with zero commits and
     nothing ever staged. No seed commit is needed to make `--uncommitted` resolve to an empty
     diff there — an earlier revision of this fix seeded a placeholder commit,
     reasoning `--uncommitted` needed a committed `HEAD` to diff against safely; that reasoning
     was wrong (a freshly-`git init`'d repo's unborn HEAD already makes `--uncommitted` resolve
     to an empty diff against git's own empty-tree object — this project's own unborn-HEAD
     handling, `git rev-parse --verify -q HEAD` then either `HEAD` or `git hash-object -t tree
     /dev/null`, already covers it), and the seed commit was also unsafe: its exit status was
     never checked, so a globally-configured `pre-commit`/`commit-msg` hook could reject it and
     leave the placeholder file STAGED but uncommitted — `--uncommitted` against this "clean"
     repo would then show a non-empty diff (the staged placeholder itself), silently defeating
     the exact "guaranteed empty diff" property this mechanism exists to provide. Removing the
     seed commit removes this failure mode entirely: there is no `git commit` call left that
     could fail, and no placeholder file left to go stray. Like `PID_FILE`/`OUT_FILE`/`FOCUS_FILE`
     (see Phase 1 step 0 below), `CLEAN_REPO_DIR` is `mktemp -d`'s own output — a path Claude
     fully controls the template of, guaranteed free of shell metacharacters — so it is simply
     printed and remembered as an exact literal string for the rest of the session, with no
     file-plus-sentinel indirection needed (unlike `REPO_ROOT_FILE`/`INSTALL_PATH_FILE`, which
     hold externally-resolved values Claude does not fully control character-by-character).

     **A non-repo-artifact round is always single-group `main`, never parallel — full stop.**
     Phase 1's sizing/mode-selection logic (below) measures review scope by counting files in a
     real diff; run against a freshly-`git init`'d, zero-file `CLEAN_REPO_DIR` it would trivially
     return `0` and there is nothing to partition by file count in the first place, so the
     parallel-mode machinery simply does not apply to this case — skip it entirely and dispatch
     exactly one group (`GROUP="main"`) against `CLEAN_REPO_DIR`.

     Dispatch every artifact-only round's wrapper call with `--cwd "<the exact literal
     CLEAN_REPO_DIR path>" --uncommitted --focus "$FOCUS_TEXT"` in place of `--cwd "$REPO_ROOT"`
     — see Phase 1 Step 1 below for exactly where this substitution applies. **A non-repo-
     artifact round always uses `--uncommitted` against `CLEAN_REPO_DIR`, never `--base`/
     `--commit`** — there is no commit in `CLEAN_REPO_DIR` to diff against, and round 2+ still
     uses `--resume` exactly as normal (the resumed thread already has the pasted artifact
     content in its own context, same as any other round 2+).

     **Cleanup:** `CLEAN_REPO_DIR` (when created this session) is removed in Phase 3 alongside
     `REPO_ROOT_FILE`/`INSTALL_PATH_FILE` — see Phase 3 below. It is created lazily (only if this
     session ever actually needs it, i.e. only in the genuine-non-repo-artifact branch above, never
     in the still-nothing-concrete-at-all branch), so Phase 3's cleanup only runs when one was
     actually allocated. (The still-nothing-concrete-at-all early exit's own `rm -f` for
     `REPO_ROOT_FILE`/`INSTALL_PATH_FILE` is already covered in that bullet above — nothing further
     to clean up there, since `CLEAN_REPO_DIR` is never allocated on that path.)

---

**Non-repo artifact round?** Substitute the exact literal `CLEAN_REPO_DIR` path (see Phase 0 step
4) for `$REPO_ROOT` in the `--cwd` argument above instead — never `$REPO_ROOT` for a genuine
non-repo-artifact review — and always keep `--uncommitted` (never `--base`/`--commit`, since
`CLEAN_REPO_DIR` has no commits to diff against). **Also run the git-environment sanitization
loop defined in `codex-stream-review/skills/ccs/SKILL.md`'s own Phase 1 Step 1 dispatch section,
immediately before that section's own "Round 1 (fresh ...)" comment.** Reuse that one fenced code block by reference only — in `codex-stream-review/skills/ccs/SKILL.md`'s own Phase 1 Step 1 dispatch section, not reproduced in this file — never retype it, never
abbreviate it, and never reproduce any piece of its actual shell syntax as a separate backtick-
quoted span anywhere in this file, including here. Multiple earlier revisions of this exact
instruction each tried to show a shortened or reflowed copy directly in prose, and each one turned
out broken in its own way once actually executed (a line break landing mid-command; an abbreviated
placeholder that parses as valid shell but silently does nothing) — this is a real,
repeatedly-reintroduced bug, not a hypothetical one, and the only fix that has actually held is
naming the one canonical block instead of ever showing a second rendering of it. **In this same
dispatch call, every round, before invoking the wrapper** — this is a separately-dispatched call and an
unset environment variable does not carry over between calls any more than a literal value does;
skipping it here would silently reopen the exact bypass Phase 0 step 4 already fixed at creation
time, on every round after the first. As explained in `codex-stream-review/skills/ccs/SKILL.md`'s own Phase 1 Step 1 dispatch block,
this does not protect the wrapper's internal collection (already safe via `git_safe()`) — it
protects `codex exec`/`codex exec resume` itself, which the wrapper launches inside a plain
`cd "$CWD"` subshell with no isolation of its own, so a leaked `GIT_DIR`/`GIT_WORK_TREE` here could
redirect Codex's own investigation-time git commands to the wrong repository (the user's real one,
not `CLEAN_REPO_DIR`) instead.
**This substitution applies to EVERY round of a
non-repo-artifact session, round 2+ included — never revert to `$REPO_ROOT` on a resume.** The
wrapper still `cd`s into whatever `--cwd` names immediately before running `codex exec resume`,
even though diff collection itself is skipped on resume — passing `$REPO_ROOT` on a resumed
artifact round would silently hand Codex's tool context back to the user's real, unrelated working
tree for that round, defeating the whole point of the isolation `CLEAN_REPO_DIR` exists to
guarantee. Only the diff-collection scope flag changes between round 1 (`--uncommitted`) and round
2+ (`--resume <threadId>`) — `--cwd "$CLEAN_REPO_DIR"` stays constant across every round of the
session. (A non-repo-artifact round is always single-group `main` — see Phase 0 step 4 and
"Determine review mode" above — so this substitution never applies to more than one group.)
