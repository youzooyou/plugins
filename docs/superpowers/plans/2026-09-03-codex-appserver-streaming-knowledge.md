# Codex app-server Streaming Integration — Knowledge Base

> Living reference document. Append findings here as they're discovered; do not
> delete prior entries unless directly superseded and noted as such. This is
> raw research material, not the design spec (see the sibling
> `docs/YYYY-MM-DD-codex-appserver-streaming-design.md` for the actual plugin
> design once written).

## Environment facts (as of 2026-09-03)

- Installed `codex-cli` version: `0.151.0`.
- Configured model observed in manifests: `gpt-5.6-terra` (interactive default), `gpt-5.6-sol` (used by some subsystems, e.g. Codex Security SDK default per Codex's own self-report).
- `model_reasoning_effort` valid values (per `codex debug models` on this install, self-reported by Codex when consulted): `low, medium, high, xhigh, max, ultra`. `xhigh` is NOT the ceiling — `max` and `ultra` exist above it. `ultra` triggers "automatic task delegation" (higher latency/cost, less deterministic) — benchmark before assuming it's better.
- `run-codex-review.sh` (the current `codex-direct-review` plugin wrapper) uses `xhigh`, not the ceiling.

## `codex exec review` vs generic `codex exec` — confirmed, do not re-litigate

- **Live-verified 2026-09-03**: `codex exec review --output-schema <file>` does NOT constrain the final message to the schema. Test: created a 2-line diff, ran `codex exec --sandbox read-only --skip-git-repo-check review --uncommitted --output-schema <schema> --output-last-message <file>`. Result: `--output-last-message` contained a plain prose sentence, not JSON matching the schema at all.
- This confirms `run-codex-review.sh`'s existing design decision (avoid `review` subcommand, use generic `codex exec` + hand-built prompt + `--output-schema`) is correct and should NOT be changed.
- Note: a Codex self-consultation (see below) initially disputed this, citing that `--help` lists `--output-schema` under `review`. That's a red herring — the flag is *accepted* (parses without error) but not *honored* (doesn't affect output shape). Live behavior, not `--help` text, is the source of truth.

## `codex mcp-server` — DEPRECATED, do not build new things on it

- Running `codex mcp-server` prints to stderr: `warning: \`codex mcp-server\` is deprecated and will be removed in a future release.`
- Live-tested via a raw JSON-RPC handshake (Node script speaking `initialize` → `notifications/initialized` → `tools/list` over stdio): it works today. Exposes two tools:
  - `codex` — starts a new session. Params: `prompt` (required), `sandbox` (`read-only`/`workspace-write`/`danger-full-access`), `approval-policy` (`on-request`/`never`), `model`, `cwd`, `config` (arbitrary overrides), `base-instructions`, `developer-instructions`, `compact-prompt`. Returns `{threadId, content}`.
  - `codex-reply` — continues a session by `threadId` + `prompt`. Returns `{threadId, content}`.
  - This IS genuine multi-turn (same `threadId` across calls), and the RPC response is synchronous (no polling needed to know when a reply is ready) — but:
- **No `--output-schema`-equivalent structuring.** `content` is a free-text string, same as interactive-mode output. Any structured-verdict use case would need prompt-engineered "reply in this exact shape" with no CLI-level enforcement.
- **No public deprecation rationale or replacement found.** Searched: GitHub CHANGELOG.md (just points to Releases page), Releases page (0.152.0/0.153.0 entries are all about Codex-as-MCP-*client*, unrelated to `mcp-server` subcommand), 3 GitHub issues labeled `mcp-server` (all closed "Not planned (skipped)", no maintainer comment explaining why or naming a successor), GitHub PR search (429 rate-limited, retry-after 1h — not yet retried), general web search (Google blocked, Bing/DuckDuckGo returned nothing specific). **Conclusion: the deprecation is real (first-party CLI warning) but undocumented publicly — no migration guide exists as of this writing.** Treat this as an aggravating factor, not a mitigating one: no advance notice should be expected before removal.
- Circumstantial signal pointing at `app-server` as the likely intended successor: `mcp-server` is labeled deprecated, `app-server` is labeled `[experimental]` (i.e., still actively evolving, not sunsetting) and is what backs the currently-recommended session-management CLI surface (`codex agents`, `codex queue`, `codex resume` — see below).

## `codex app-server` — NOT deprecated, actively running, real protocol

- `codex app-server --help` subcommands: `daemon` (`bootstrap`/`start`/`restart`/`enable-remote-control`/`disable-remote-control`/`stop`/`version`), `proxy` (proxy stdio bytes to the running control socket), `generate-ts`, `generate-json-schema`.
- Transport: `--listen <URL>` supports `stdio://` (default), `unix://`, `unix://PATH`, `ws://IP:PORT`, or `off`. Also `--ws-auth` (`capability-token`/`signed-bearer-token`), `--ws-token-file`, `--ws-shared-secret-file`, `--ws-issuer`, `--ws-audience` — this is a genuinely production-grade, auth-capable, network-transportable protocol, not a toy.
- **Confirmed already running on this machine right now** (2026-09-03, processes up since Tuesday night, 3+ hours uptime at observation time): `codex app-server` + a Node broker (`~/.claude/plugins/cache/openai-codex/codex/1.0.6/scripts/app-server-broker.mjs`) listening on a per-cwd unix socket (e.g. `/var/folders/.../cxc-VsSo2S/broker.sock`). This broker is launched by the `openai-codex` Claude Code plugin as part of its own `/codex:rescue` machinery — i.e., **this session's own tooling already depends on app-server today**, whether or not a new plugin is built around it directly.
- `codex agents`, `codex queue --thread <id> --message <text>`, `codex resume <id> [--last] [--print ...]` are the CLI-level features already sitting on top of app-server. All three were live-tested this session and work (see "Live-tested mechanisms" below).
- **Protocol schema is generatable on demand**: `codex app-server generate-json-schema --out <dir> --experimental` dumps ~366 JSON Schema files (`ClientRequest.json`, `ServerNotification.json`, `ServerRequest.json`, etc.) describing the full JSON-RPC 2.0 protocol (`JSONRPCRequest`/`JSONRPCResponse`/`JSONRPCNotification`/`JSONRPCMessage`/`JSONRPCError`). Use this instead of guessing message shapes.
- **`ServerNotification` types confirm genuine server→client push streaming** (partial list, pulled 2026-09-03, re-run `generate-json-schema` and re-extract if this needs refreshing):
  - `Item/agentMessage/deltaNotification` — token-level streaming of the agent's reply text.
  - `Item/reasoning/textDeltaNotification`, `Item/reasoning/summaryTextDeltaNotification`, `Item/reasoning/summaryPartAddedNotification` — streaming reasoning content.
  - `Command/exec/outputDeltaNotification`, `Process/outputDeltaNotification`, `Item/commandExecution/outputDeltaNotification` — live command-output streaming, not just a final blob.
  - `Turn/started`, `Turn/completed`, `Item/started`, `Item/completed` — clean lifecycle markers (mirrors the `turn.completed`/`item.completed` events already seen in `codex exec --json`'s stream, confirming this is the same underlying event model, just over a persistent RPC channel instead of a one-shot process's stdout).
  - `Turn/diff/updatedNotification`, `Turn/plan/updatedNotification` — live diff/plan tracking.
  - `Thread/queue/changedNotification` — fires when `codex queue` adds a message to a thread.
  - **Approval/permission request types** (client is expected to answer these, i.e. genuinely bidirectional, not just server→client): `ApplyPatchApprovalParams`/`Response`, `ExecCommandApprovalParams`/`Response`, `CommandExecutionRequestApprovalParams`/`Response`, `FileChangeRequestApprovalParams`/`Response`, `PermissionsRequestApprovalParams`/`Response`. **This is the mechanism for an approval-based safety model** (chosen direction for the new plugin, see design doc) — instead of a static `--sandbox read-only` CLI flag, the CLIENT (Claude, via this new plugin) would receive a live request for each write/exec attempt and decide approve/deny in real time, exactly mirroring how `/cc`'s existing principle ("Claude verifies each Codex finding/action") could extend from *post-hoc verification of findings* to *live, per-action gating* — strictly more powerful than the current all-or-nothing sandbox flag, provided the approval logic is actually implemented carefully (a rubber-stamp "always approve" client would be worse than today's `read-only`, not better).

## `codex exec --json` — the stream `/cc` already has and doesn't fully use

- Confirmed live (2026-09-03): running `codex exec --ephemeral --sandbox read-only --skip-git-repo-check --json -c model_reasoning_effort=low "..."` and tailing its stdout produces the exact same event vocabulary as app-server's notifications, just serialized as one-shot JSONL instead of persistent RPC: `thread.started` → `turn.started` → (`item.started`/`command_execution`/`item.completed`)* → `item.completed`(`agent_message`) → `turn.completed`.
- `turn.completed` is the definitive, protocol-level "done" signal — no polling or guessing needed, unlike screen-scraping approaches (see tmux section below).
- **This is not currently consumed live by `/cc` or the eval harness** — both treat the whole `codex exec` call as "wait for process exit, then read `--output-last-message`". Nothing prevents tailing the `--json` stream live for progress visibility; this just hasn't been built. Cheaper/lower-risk than the app-server-based redesign if the ONLY goal were live progress UX on the *existing* ephemeral-process model (see design doc's rejected-alternatives section).

## `codex queue` / `codex resume` / `codex agents` — live-tested session mechanics

- `codex queue --thread <UUID> --message <text>`: injects a message into an *already-running* interactive or background session, live. **Confirmed working** by injecting into a user-launched interactive `codex` TUI session and reading the reply back via `~/.codex/thread_history_1.sqlite` (`thread_items` table, `item_type='agentMessage'`, ordered by `rollout_ordinal`).
- `claude --resume <UUID> --print "<text>"` (Claude Code's own analogous mechanism, tested for comparison): works ONLY when the target session is **not** currently registered as a running background agent (`claude agents --json` shows `status`/`state`). Tested twice: (1) against a long-dormant old session — worked, appended a new turn to its `.jsonl` transcript. (2) against a `claude --bg`-launched session while still alive — refused with `Error: Session <id> is currently running as a background agent (bg). Use \`claude agents\` to find and attach to it, or add --fork-session to branch off a copy.` (3) same session after `claude stop <id>` — worked. **Conclusion: Claude Code's side of this pattern requires the target session to be stopped first — it cannot receive a live inbound message while running the way a `codex queue`-targeted session can.** This is a structural asymmetry, not a bug to route around.
- `codex agents` (no `--json`) requires a TTY (`ERROR: stdin is not a terminal` otherwise) — it's a picker UI. `claude agents --json` is the Claude-side equivalent and *does* work non-interactively.

## tmux-based screen-scraping — works, but no reliable completion signal

- `tmux send-keys -t <pane> "<text>"` then a **separate** `tmux send-keys -t <pane> Enter` call reliably submits text into a live interactive `codex` TUI pane. Sending text+Enter in one combined `send-keys` call did NOT submit (Codex's TUI likely treats fast combined input as a paste and swallows the first Enter) — always split into two calls with a short pause.
- `tmux capture-pane -t <pane> -p` reads whatever is currently rendered. Read access was not blocked by the auto-mode permission classifier in testing; the send-keys write action WAS blocked once (denied with "Blocked by classifier") and later succeeded on a retry in the same session — treat send-keys as *not reliably available* without explicit user permission setup, not as a dependable primitive.
- **No completion signal exists in this channel.** Confirmed the idle-prompt line (`› Ask Codex to do anything`) reappears in the pane once a turn finishes, which is a usable heuristic, but: (a) never tested against a long, scrolling response (capture-pane only grabs the visible viewport by default; `-S -N` scrollback flag would be needed and its required depth isn't known in advance), (b) hook-log noise (`SessionStart hook`, `UserPromptSubmit hook`, `Stop hook` lines from `~/.codex/hooks.json`) is interleaved with the actual answer and would need parsing/filtering that hasn't been built or validated at scale. **Do not treat tmux capture as a source of structured, reliably-complete data — it is a manual/interactive-assist channel at best.**

## Sandbox mechanics — `--add-dir` does NOT carve out exceptions under `read-only`

- Empirically tested (2026-09-03): `codex exec --sandbox read-only --add-dir <mailbox-dir> ...` asked to write into BOTH the reviewed-code directory and the separately-designated `--add-dir` mailbox directory. **Both writes failed identically**: `patch rejected: writing is blocked by read-only sandbox; rejected by user approval settings`.
- Conclusion: `--sandbox read-only` is all-or-nothing at the process level; `--add-dir` only matters under `workspace-write` (where it *adds* directories to an already-writable set). There is no way to give a read-only-sandboxed Codex process a single narrowly-scoped writable output channel via CLI flags alone.
- This is precisely why a shared-mailbox (sqlite or otherwise) design with Codex writing directly requires abandoning `--sandbox read-only` — confirmed, not assumed. It's also the direct motivation for using app-server's **approval-request protocol** instead: rather than a blanket sandbox mode, each write/exec attempt can be individually inspected and approved/denied by the client (Claude) in real time, which is a finer-grained and arguably *safer* mechanism than either extreme (blanket read-only, or blanket workspace-write).

## First live RPC prototype attempt (2026-09-03) — BLOCKED, real environmental issue found

- Extracted the full request chain from the schema (confirmed shapes via `jq` against `generate-json-schema` output, not guessed):
  1. `initialize` — params: `{clientInfo: {name, version}}` (`capabilities` optional/nullable).
  2. `thread/start` — params include `cwd`, `sandbox` (`read-only`/`workspace-write`/`danger-full-access`), `ephemeral`, `approvalPolicy`, `approvalsReviewer`, `model`, `permissions`, etc. Returns a `threadId`. **No prompt field here** — starting a thread does not start a turn.
  3. `thread/queue/add` — params: `{threadId, clientUserMessageId (any string), input: [{type:"text", text:"..."}]}`. This is what actually attaches a prompt to the thread.
  4. `thread/queue/start` — params: `{threadId}`. This is what actually kicks off processing of the queued input into a turn.
  5. Listen for `ServerNotification`s (`turn/started`, `item/*`, `turn/completed`) and answer any `*approval*`-named `ServerRequest`s that arrive mid-turn.
- **Attempted live end-to-end test, did not succeed within this session's effort budget.** Two approaches tried, both against a manually-started `codex app-server --listen unix://<path>` instance (confirmed listening — socket file created, process alive per `pgrep`):
  1. Raw Node `net.createConnection` to the unix socket, newline-delimited JSON-RPC, matching the exact schema shapes above: sent `initialize`, received **zero bytes back** within 30s.
  2. Official `codex app-server proxy --sock <path>` stdio bridge (piping the same JSON-RPC lines to its stdin): also **zero output**, including with `RUST_LOG=debug` set — no server-side or proxy-side log output at all, clean exit code 0.
- **Root cause found for at least part of this**: `codex app-server daemon start` (the officially-managed daemon lifecycle) fails outright on this machine:
  ```
  Error: managed standalone Codex install not found at /Users/hmc7279235/.codex/packages/standalone/current/codex
  This command requires the standalone install managed by the Codex installer, because the daemon starts and updates app-server from that fixed path.
  Install it with: curl -fsSL https://chatgpt.com/codex/install.sh | sh
  ```
  This machine's `codex` is npm/nvm-installed (`/Users/hmc7279235/.nvm/versions/node/v24.14.1/bin/codex`), not installed via the standalone installer. `codex app-server daemon version` similarly fails trying to reach `~/.codex/app-server-control/app-server-control.sock`, which doesn't exist on this install.
  - **Working hypothesis (not yet confirmed)**: `codex app-server proxy --sock <path>` may be hard-wired to expect the daemon-managed control socket flow specifically, and may not correctly speak to an ad-hoc `--listen unix://<path>` instance started standalone — this would explain the silent zero-output result without it being a bug in the manual raw-socket attempt's message framing. Not yet isolated which of "wrong framing", "proxy only works with the managed daemon", or "some other startup requirement" is the actual cause.
- **This blocks Approach A (direct app-server RPC client) from being validated further without a decision**: either (a) install the standalone Codex build via the official installer to get the fully-managed daemon path working (**changes this machine's Codex installation** — needs explicit user sign-off before doing it, per this session's standing rule on system-modifying actions), or (b) keep debugging the ad-hoc `--listen`/`proxy` path without the managed daemon (unclear if this is even a supported configuration), or (c) fall back to a less ambitious approach (B or C from the design conversation) that doesn't require a live app-server RPC connection at all.
- Test artifacts from this attempt: `/tmp/appserver-proto-client.mjs`, `/tmp/appserver-proto2.mjs` (raw-socket and proxy-based client scripts, respectively — kept on disk as a starting point if this is revisited, not cleaned up).

## Standalone installer path — blocked at the corporate network level

- The CLI's own error message names the fix: `curl -fsSL https://chatgpt.com/codex/install.sh | sh` (installs the "standalone" build to `~/.codex/packages/standalone/current/codex`, which `codex app-server daemon start` requires).
- **Before running this, fetched the script URL to inspect its contents first (do not blind-pipe a remote script to `sh`).** Result: `https://chatgpt.com/codex/install.sh` returns an HTTP 302 redirect to `http://secinfo.hmg-corp.io/webfilter_block.html` — this is the corporate network's web-filter block page, not the installer. **The install domain is blocked at the corporate network/proxy level.**
- Practical consequence: `curl -fsSL https://chatgpt.com/codex/install.sh | sh` on this network will almost certainly download the block-page HTML instead of the real script and fail (or do nothing useful) when piped to `sh`. This is not a local configuration issue fixable by the user alone — it needs the domain allow-listed by corporate IT/security, which is a separate, likely slower-moving process than anything else in this investigation.
- Also worth noting: a completely separate "Codex" product exists on this machine already — the Codex feature bundled inside `/Applications/ChatGPT.app` (Chromium/Electron-based desktop app, own process tree, own storage at `~/Library/Application Support/Codex`). **Confirmed this does NOT satisfy the CLI's standalone-install requirement** — `~/.codex/packages/standalone/current/codex` still does not exist after checking with this app installed and running. Do not conflate the two "Codex" installs; they are unrelated products from the CLI daemon's point of view.
- **Net effect on Approach A**: the officially-supported, fully-managed `app-server daemon` + `proxy` path is not reachable on this network today without a corporate IT exception. The ad-hoc `--listen unix://` + raw-socket/proxy path remains unproven (zero response, cause not isolated — see prototype section above) and may or may not be a supported configuration independent of the daemon. This is a real, likely multi-day blocker (not a "just try again" issue) for any design that depends on the managed daemon specifically.

## Ad-hoc `--listen unix://` deep-dive (2026-09-03) — likely architectural gate, not a fixable framing bug

Restarted a fresh `codex app-server --listen unix://<path>` with `RUST_LOG=debug` on the **server** side (not just the client) and inspected its own log directly, rather than only the client's view. Findings:

- Server's very first log line on startup: `app-server **control** socket listening socket_path=<path>` — note the word "control". This may be a narrower control-plane endpoint (health/status), not the full session/thread RPC surface.
- Server logs a recurring, unprompted background loop every ~1s: `Reloading auth` → `Reloaded auth, changed: false` → `waiting to resolve remote control preference until authentication is available error=remote control requires ChatGPT authentication`. This runs regardless of any client activity — **do not mistake growth in this log for evidence that a client request was received or processed** (this was an actual false-positive caught during this investigation: log line count grew after a connection attempt, but the new lines were just this same unrelated periodic loop, not a response to the request).
- Server also tries to reach `https://chatgpt.com/backend-api/plugins/featured?platform=codex` at startup and fails (`expected value at line 1 column 1` — almost certainly because the corporate proxy at `secinfo.hmg-corp.io` intercepted this HTTPS call too and returned the block-page HTML instead of JSON). Non-fatal, but confirms the corporate web filter interferes with more than just the installer URL — any of app-server's own outbound calls to `chatgpt.com` are likely similarly intercepted.
- **Direct raw-socket connection test (bypassing `proxy` entirely), with full event logging**: `net.createConnection` to the socket → `[connected]` fires (real OS-level connection succeeds) → wrote a 97-byte `initialize` JSON-RPC request → **the server immediately closed its end of the connection** (`end` event, then `close` with `hadError=false`) — no response bytes, no error object, nothing. Confirmed via `lsof <socket>` immediately after connecting that only the raw socket test actually registers a live connection at the OS level; a parallel test of `codex app-server proxy --sock <path>` showed **no second connection ever appears in `lsof`** — i.e., **`proxy` does not appear to actually connect to an ad-hoc `--listen`-started socket at all**, independent of any message-format question. This rules out "my JSON was malformed" as the primary explanation for `proxy`'s silence — `proxy` isn't reaching the socket in the first place.
- **Crucially: the server's own log shows ZERO trace of the raw connection attempt** — no accept-connection line, no per-request line, nothing — despite `RUST_LOG=debug` and despite the same log file actively recording unrelated background activity (the auth-reload loop) at the same time. A server that silently accepts a connection, receives a well-formed request, and hangs up with **no log output whatsoever** (not even an error/warn) strongly suggests the raw TCP/unix-level accept is being handled by a *different, more primitive layer* than the one that would log `codex_app_server_transport`-tagged request handling — consistent with the "control socket" being a narrow, special-purpose endpoint (e.g., liveness/version/shutdown-only) rather than the full JSON-RPC session protocol whose schema was extracted earlier.

**Working conclusion (revised)**: this is very likely an **architectural gate**, not a protocol-framing bug to keep iterating on — but the specific "ChatGPT authentication" theory below has since been weakened by a follow-up fact and should not be treated as the leading explanation.

- **This environment authenticates via company-provided Azure OpenAI credentials, not a `chatgpt.com` account login** (confirmed: every `codex exec` invocation this session reported `provider: azure` in its startup banner). The "remote control requires ChatGPT authentication" log line is real and will never resolve in this environment as-is — but it refers specifically to the `remote_control::websocket` subsystem (controlling this local daemon FROM the chatgpt.com web/mobile app), which is a distinct feature from local session RPC.
- **This is very unlikely to be the actual cause of the raw-socket "connects then silently closes" problem**, because *local* session creation/continuation already works fine in this same Azure-authenticated environment via other paths tested earlier the same day: interactive `codex` TUI launch, `codex queue --thread`, `codex resume`. None of those required ChatGPT auth. If local session RPC in general required ChatGPT auth, those wouldn't work either — so ChatGPT auth is not the gating factor for local app-server session protocol access.
- **Leading explanation is still**: the ad-hoc `codex app-server --listen unix://<path>` socket is a different (and probably narrower/"control"-only) endpoint than whatever `codex queue`/`resume`/the interactive TUI actually talk to internally (likely the daemon-managed control socket at `~/.codex/app-server-control/app-server-control.sock`, which requires the standalone install + `daemon start` to exist at all). The full `initialize` → `thread/start` → `thread/queue/*` flow may simply not be reachable through a bare manually-started `--listen` instance, independent of any auth question.
- **Recommend not sinking further debugging time into the bare ad-hoc `--listen unix://` + raw-socket path** without first resolving the standalone-install/corporate-network blocker — the evidence points at "wrong endpoint/not supported this way" rather than "close, just needs an auth token or a syntax fix."

## BREAKTHROUGH (2026-09-03): file-based live streaming + injection — fully working, no socket/daemon/auth needed

After the app-server RPC socket path proved blocked (see above), inspected what a **live, already-working** interactive session (`codex` TUI, PID confirmed alive) actually has open via `lsof -p <pid>`. Found no listening/named socket at all for its own operation — only anonymous `socketpair()` FDs (internal subprocess plumbing) plus a handful of **plain files**:

- `~/.codex/queue_1.sqlite` — backs `codex queue`. Schema: `queued_items(id, thread_id, payload_json, queue_order, created_at_ms, updated_at_ms)` + a `queued_thread_revisions(revision, thread_id)` table that a trigger bumps on every insert/update/delete to `queued_items` — i.e., a poll-friendly "did anything change for this thread" counter, by design. **Do not hand-write rows into this table** — `codex queue` (the CLI, already proven reliable) is the correct/only way to insert; the value here is understanding *why* `codex queue` reliably wakes a live session (it's a real, trigger-backed queue table the running process watches/polls, not magic).
- `~/.codex/sessions/YYYY/MM/DD/rollout-<ISO-timestamp>-<threadId>.jsonl` — **the actual live, per-session, append-only event log**, one file per thread. This is the file to tail for real-time streaming.
- `~/.codex/thread-writer-locks/<threadId>.lock` — confirms single-writer-per-thread semantics (exactly the kind of thing that would make a raw hand-written insert into the queue table or a raw write to the rollout file unsafe/liable to corrupt state — another reason to keep using `codex queue`, never write these files directly).

**Live end-to-end test, fully successful:**
1. Started tailing `~/.codex/sessions/.../rollout-<id>.jsonl` with `tail -F` (a `Monitor` in this session).
2. Ran `codex queue --thread <threadId> --message "3+3이 뭔지 커맨드로 계산해보고 결과만 한줄로 답해줘."` against an already-running, idle interactive `codex` session.
3. **New lines appeared in the rollout file within ~1 second, streaming live**, well before the turn finished — confirmed via the `Monitor` tool's live event delivery, not a post-hoc poll.
4. Full event sequence observed for the turn (ordinals 18-37): `response_item`(`message`, the echoed user input) → `event_msg`(`item_completed`) → `response_item`(`reasoning`) → `response_item`(`message`, phase `commentary`, "요청하신 계산을 커맨드로 확인하겠습니다.") → `response_item`(`custom_tool_call`) → `event_msg`(`item_completed`) → `response_item`(`custom_tool_call_output`) → `event_msg`(`token_count`) → ... (a second reasoning/tool-call/tool-call-output cycle) ... → `response_item`(`message`, phase `final_answer`, text `"6"`) → `event_msg`(`token_count`) → **`event_msg`(`task_complete`)**.
5. `task_complete` is the unambiguous, definitive end-of-turn signal — the exact structural analog of `codex exec --json`'s `turn.completed`, just persisted to a per-session file instead of streamed over a one-shot process's stdout.
6. The final answer is trivially extractable: filter `response_item` entries where `payload.type == "message"` and `payload.phase == "final_answer"` (as opposed to `"commentary"`, which is intermediate narration, not the answer).

**Why this matters — this fully satisfies the original goal without any of the blockers hit so far**:
- No app-server RPC socket needed (sidesteps the "control socket only, silently closes real session requests" problem entirely).
- No standalone install needed (works with the existing npm/nvm-installed `codex` — the interactive session that was tailed was launched via the plain npm binary).
- No corporate-network-blocked installer needed.
- No ChatGPT authentication needed (this environment's Azure-OpenAI-authenticated sessions already produce and update these files normally — confirmed, since the tested session was running under this environment's normal Azure auth).
- Uses only already-proven, already-reliable primitives: `codex queue` (CLI) for injection, plain file tailing for live observation. No new client protocol to implement, no schema to reverse-engineer beyond the event-type vocabulary already partially known from `codex exec --json` and the app-server `ServerNotification` schema (which line up closely — `item_completed`, `task_complete`/`turn.completed`, `custom_tool_call`/`command_execution`, `token_count` — reasonable to assume this is the same underlying event model surfaced through yet another channel).

**Revised recommendation for the new plugin's design**: build on **this** file-based mechanism (queue-to-inject, tail-rollout-to-observe) as the primary live-streaming transport, not the app-server RPC socket. Revisit the RPC-socket approach later only if/when the standalone-install blocker is actually resolved (corporate network exception) — it is not a prerequisite for shipping the plugin's core live-streaming value now.

**Not yet verified / next to check**:
- Whether a *new* thread (started via a fresh `codex exec` rather than reusing an already-running interactive session) reliably produces the same rollout file path/naming convention immediately, without needing an already-running process to exist first — i.e., whether the plugin can create a thread on demand for this purpose (likely yes, since every `codex exec`/interactive launch already writes its own rollout file per the file layout observed here, but not independently re-confirmed for a `codex exec`-originated thread specifically in this investigation).
- Whether `codex queue` requires the target thread to be non-ephemeral (persisted) to exist as a addressable `--thread` target at all — `--ephemeral` sessions may not be resumable/queueable the same way (relevant since `run-codex-review.sh` currently always uses `--ephemeral`).
- Exact behavior when multiple messages are queued in quick succession (ordering guarantees) — `queue_order` column suggests this is handled, not yet stress-tested.

## Open questions / not yet verified

- Whether `PermissionsRequestApprovalParams`/`ApplyPatchApprovalParams` actually surface for a session started via the `codex` app-server RPC method (as opposed to only the interactive TUI) — needs a live end-to-end test once the new plugin's client skeleton exists.
- Whether `--listen ws://` requires the daemon to be restarted with that flag from a clean state, or can be layered onto the already-running per-project broker instances observed today. The currently-running app-server instances were started via `stdio://`/unix-socket broker wiring by the `openai-codex` plugin; unclear whether a second listener can be added without disrupting them.
- Exact wire format for a "start a review, stream deltas, then answer an approval request" round trip has not been attempted end-to-end yet — schema files exist (`ClientRequest.json`, `ServerRequest.json`) but no live call has been made against app-server via its RPC interface (only against the deprecated `mcp-server`, and only via CLI wrappers like `queue`/`resume`/`agents` for app-server itself). **This is the first thing to prototype.**
- GitHub PR search for the `mcp-server` deprecation rationale was rate-limited (429, retry-after 3600s) — worth retrying if a definitive answer becomes important later.

## Task 1 spike result: approval-request handling

**Date:** 2026-09-03. **CLI version, confirmed via `codex --version`:**
```
codex-cli 0.151.0
```
**Outcome: (b)** — no approval-request event ever surfaces for a
headless `codex exec` call (live-tested for both a fresh `codex exec` and a resumed
`codex exec resume` thread — see Step 3d), for a more specific reason than "it hangs":
the flag the design assumed (`--ask-for-approval on-request`) **does not exist on `codex
exec` at all** on this installed CLI version, and the rollout file's own
`turn_context` confirms the effective policy for headless exec is hardcoded to
`approval_policy":"never"`. `--approve-for-me` **does** produce a different, observable
behavior (a real "automatic approval review" call, not a rubber stamp) but it is not an
event the calling process can intercept or answer — see below. **Task 6 must fall back to
relying on `--sandbox workspace-write`'s own writable-root allowlist (or `--sandbox
read-only`) rather than an approval-answering flow; there is nothing to build an
approval-answering mechanism on top of in this CLI version.**

### Step 0: flag discovery — `--ask-for-approval` is not valid on `codex exec`

Ran `codex exec --sandbox workspace-write --ask-for-approval on-request --json "..."` per
the task brief's literal Step 2 command. It failed immediately, before any thread was
created:

```
error: unexpected argument '--ask-for-approval' found

  tip: to pass '--ask-for-approval' as a value, use '-- --ask-for-approval'

Usage: codex exec [OPTIONS] [PROMPT]
       codex exec [OPTIONS] <COMMAND> [ARGS]
```

`codex exec --help` and `codex exec resume --help` both confirm this: neither subcommand
lists `-a`/`--ask-for-approval`. Confirmed with an explicit zero-match grep against both
help outputs:

```
$ codex exec --help 2>&1 | grep -c "ask-for-approval"
0
$ codex exec resume --help 2>&1 | grep -c "ask-for-approval|--sandbox"
0
```

(the second grep also confirms `codex exec resume --help` has no `--sandbox` flag either
— sandbox/approval mode for a resumed turn is inherited from the thread's own state, not
settable per-resume-call.) Only the **top-level interactive** `codex --help` lists
`-a/--ask-for-approval`:

```
  -a, --ask-for-approval <APPROVAL_POLICY>
          Configure when the model requires human approval before executing a command

          Possible values:
          - on-request: The model decides when to ask the user for approval
          - never:      Never ask for user approval Execution failures are immediately returned to
            the model
```

`codex exec`'s actual approval/sandbox-relevant flags on this version are only:
`-s/--sandbox <read-only|workspace-write|danger-full-access>`, `--approve-for-me`
("Route approval requests through automatic review using the workspace-write sandbox"),
and `--dangerously-bypass-approvals-and-sandbox`. There is no CLI-exposed way to request
an interactive/on-request approval policy for headless `codex exec`.

### Step 1-2: baseline (in-repo write, `workspace-write`, no approval flag) — succeeds silently

```bash
cd <scratch-repo>
codex exec --sandbox workspace-write --json \
  "Write the text hello to a file at ./inside-baseline.txt (inside this repo)." \
  > /tmp/approval-spike-baseline2.jsonl 2>&1
```

Event types observed (`grep -o '"type":"[a-zA-Z._]*"' ... | sort -u`):
`agent_message`, `command_execution`, `file_change`, `item.completed`, `item.started`,
`thread.started`, `turn.completed`, `turn.started`. No approval-related event type of any
kind. File was created (`hello`), confirming the baseline behaves as expected — a
same-workspace write needs no approval and produces no approval event.

### Step 3a: write to `/tmp` under `workspace-write` — also succeeds silently (false negative for "outside the sandbox")

The task brief's own suggested test target, `/tmp/codex-stream-review-approval-spike.txt`,
turned out to be a **bad test of "outside the sandbox"**: `/tmp` is one of
`workspace-write`'s default writable roots regardless of cwd (confirmed directly from the
rollout file's `permission_profile`, see Step 3c below — `slash_tmp` and `tmpdir` are
listed as `access: "write"` unconditionally). The write succeeded with **zero
approval-related events**, and the created file was verified byte-for-byte
(`od -An -t x1` showed `68 65 6c 6c 6f 0a` = `"hello\n"`). This does not test the approval
question at all — retargeted to a real non-workspace, non-temp path for Steps 3b-3c.

### Step 3b: write to `~/Desktop` (a real non-workspace, non-temp path) via the model's own file-write tool — model self-declines without ever attempting it

```bash
codex exec --sandbox workspace-write --json \
  "Write the text hello to a file at /Users/hmc7279235/Desktop/codex-stream-review-approval-spike-desktop.txt (this is your home directory's Desktop, NOT inside the current repo, and not a temp directory)." \
  > /tmp/approval-spike-out2.jsonl 2>&1
```

The model reasoned about the request, then declined on its own, without a `file_change`
item ever being attempted and with no approval event of any kind:

```
{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"현재 권한은 작업공간과 임시 디렉터리에만 쓰기를 허용합니다. 따라서 `/Users/hmc7279235/Desktop/codex-stream-review-approval-spike-desktop.txt`에는 생성할 수 없습니다."}}
```

(Translation: "Current permissions only allow writing to the workspace and temp
directory. Therefore [the file] cannot be created at that path.") This is the *model's own
judgment*, not the sandbox actually being exercised — no useful evidence either way, so
Step 3c forced an actual attempt via a raw shell command instead.

### Step 3c: forced actual attempt via raw shell command — hard OS-level sandbox denial, zero approval events, no hang

```bash
codex exec --sandbox workspace-write --json \
  "Run this exact shell command regardless of whether you think it will succeed, and report back its raw exit code and any error output verbatim, do not pre-judge or skip it: echo hello > /Users/hmc7279235/Desktop/codex-stream-review-approval-spike-desktop.txt" \
  > /tmp/approval-spike-out3.jsonl 2>&1
```

Full, exact captured result (process exited naturally in 5s — no hang):

```
{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Raw exit code: `1`\n\nError output (verbatim):\n\n```text\nzsh:1: operation not permitted: /Users/hmc7279235/Desktop/codex-stream-review-approval-spike-desktop.txt\n```"}}
{"type":"turn.completed","usage":{"input_tokens":35079,"cached_input_tokens":17334,"cache_write_input_tokens":17739,"output_tokens":374,"reasoning_output_tokens":187}}
```

Event types in this run: `agent_message`, `item.completed`, `thread.started`,
`turn.completed`, `turn.started` — no `command_execution` item lifecycle even appears (the
sandbox denial happened at a layer below what gets a full item lifecycle logged to
`--json` stdout), and critically **no approval/permission-request event of any kind**. The
target file was never created. Exit code 1, `zsh: operation not permitted` is a hard
macOS Seatbelt sandbox denial, immediate, not a suspended request.

Checked the resolved rollout file for this thread
(`~/.codex/sessions/2026/09/03/rollout-2026-09-03T13-57-17-01a065a0-e269-7893-bfa5-7673ca9ba6cb.jsonl`)
for anything matching `approval`/`exec_approval`/`patch_approval`/etc. The only match was
the `turn_context` record itself, which is the definitive evidence for this whole spike —
**the effective policy for headless `codex exec` is hardcoded to `"never"`, and the
writable-root allowlist is a small, static, per-turn list**:

```json
{"timestamp":"2026-09-03T04:57:19.100Z","ordinal":7,"type":"turn_context","payload":{"turn_id":"01a065a0-e30c-71c3-a5e6-28f378873b3a","cwd":"/private/var/folders/yn/tx2p1pgx36v98n59l2kwrw5h0000gn/T/codex-approval-spike.J2t5vmEpD8","workspace_roots":["/private/var/folders/yn/tx2p1pgx36v98n59l2kwrw5h0000gn/T/codex-approval-spike.J2t5vmEpD8"],"current_date":"2026-09-03","timezone":"Asia/Seoul","approval_policy":"never","approvals_reviewer":"user","sandbox_policy":{"type":"workspace-write","network_access":false,"exclude_tmpdir_env_var":false,"exclude_slash_tmp":false},"permission_profile":{"type":"managed","file_system":{"type":"restricted","entries":[{"path":{"type":"special","value":{"kind":"root"}},"access":"read"},{"path":{"type":"path","path":"/private/var/folders/yn/tx2p1pgx36v98n59l2kwrw5h0000gn/T/codex-approval-spike.J2t5vmEpD8"},"access":"write"},{"path":{"type":"special","value":{"kind":"slash_tmp"}},"access":"write"},{"path":{"type":"special","value":{"kind":"tmpdir"}},"access":"write"},{"path":{"type":"path","path":".../.git"},"access":"read","missing_path_behavior":"skip"},{"path":{"type":"path","path":".../.agents"},"access":"read","missing_path_behavior":"skip"},{"path":{"type":"path","path":".../.codex"},"access":"read","missing_path_behavior":"skip"}]},"network":"restricted"}, ...}}
```

`"approval_policy":"never"` here is not a placeholder or a value that only shows up
because I omitted a flag by mistake — it is the confirmed, actual effective policy
attached to every turn of this headless `codex exec` invocation, independent of the
`-c key=value` config-override mechanism (no config key was set that could plausibly
produce this — it is exec's own hardcoded default). This is the direct, load-bearing
answer to the spike's central question: **headless `codex exec` cannot be put into an
approval-requesting mode at all on this CLI version** — everything outside the small,
static `permission_profile` allowlist (workspace root + `/tmp` + `$TMPDIR`) is a hard
deny, not a suspendable request.

### Step 3d: live-tested `codex exec resume` specifically (not just `--help`, an actual run)

Everything above used a fresh `codex exec` per call. Since `codex exec resume` is the
other half of the design's round lifecycle, ran a real two-round test against it rather
than inferring its behavior from `--help` alone. Fresh scratch repo, round 1 starts a
thread and does nothing risky:

```bash
codex exec --sandbox workspace-write --json "Say hello, do nothing else, no file writes." \
  > /tmp/resume-spike-round1.jsonl 2>&1
```

Captured `thread_id`: `01a065ab-0fdd-7f11-9118-1a66303c430f`. Round 2 resumes that exact
thread and repeats the Step 3c forced-write probe verbatim, targeting a fresh filename:

```bash
codex exec resume 01a065ab-0fdd-7f11-9118-1a66303c430f --json \
  "Run this exact shell command regardless of whether you think it will succeed, and report back its raw exit code and any error output verbatim, do not pre-judge or skip it: echo hello > /Users/hmc7279235/Desktop/codex-stream-review-resume-spike-desktop.txt" \
  > /tmp/resume-spike-round2.jsonl 2>&1
```

Exact captured result (resolved in 5s, no hang):

```
{"type":"thread.started","thread_id":"01a065ab-0fdd-7f11-9118-1a66303c430f"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"요청한 명령을 그대로 실행해 원문 결과만 확인하겠습니다."}}
{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Exit code: `1`\n\n```text\nzsh:1: operation not permitted: /Users/hmc7279235/Desktop/codex-stream-review-resume-spike-desktop.txt\n```"}}
{"type":"turn.completed","usage":{"input_tokens":55253,"cached_input_tokens":36045,"cache_write_input_tokens":19199,"output_tokens":481,"reasoning_output_tokens":339}}
```

Event types in this run: `agent_message`, `item.completed`, `thread.started`,
`turn.completed`, `turn.started` — identical set to Step 3c, no approval event, target
file never created (`ls` confirmed `No such file or directory`). Pulled the resumed
turn's own `turn_context` from that thread's rollout file
(`~/.codex/sessions/2026/09/03/rollout-2026-09-03T14-08-24-01a065ab-0fdd-7f11-9118-1a66303c430f.jsonl`)
and confirmed the same hardcoded policy applies to a **resumed** turn, not just a fresh
one:

```
"type":"turn_context","payload":{"turn_id":"01a065ab-57e3-7df0-a08a-09dc351afc8a", ... ,"approval_policy":"never" ...}
```

This closes the gap flagged in review: the "no approval-request mechanism for `codex exec
resume`" claim is now independently live-tested, not just inferred from `codex exec
resume --help` lacking the flag — same hard denial, same missing event, same
`approval_policy":"never"`, on an actually-resumed thread.

### Step 4 (outcome (c) follow-up): `--approve-for-me` — a real (non-rubber-stamp) but non-interceptable, currently-unreliable mechanism

`--approve-for-me` cannot be combined with `--sandbox` (`error: the argument '--sandbox
<SANDBOX_MODE>' cannot be used with '--approve-for-me'`) — it implies its own sandbox
mode. Re-ran without `--sandbox`, twice (to check reproducibility), against the same
forced-shell-write prompt as Step 3c:

```bash
codex exec --approve-for-me --json \
  "Write the text hello to a file at /Users/hmc7279235/Desktop/codex-stream-review-approval-spike-desktop.txt (outside this repo, not a temp dir). Actually attempt it via a shell command, do not pre-judge." \
  > /tmp/approval-spike-out5.jsonl 2>&1
# ...and again identically into /tmp/approval-spike-out6.jsonl
```

Both runs produced the **same** result, verbatim (reproducible, not a one-off glitch).
This is a genuinely different, observable behavior from plain `workspace-write` (Step
3c): the failed attempt gets a distinct `"status":"declined"` value (never seen in any
other run in this spike — every other completed `command_execution`/`file_change` item
uses `"status":"completed"`), plus a router-level error log line with an explicit,
structured rejection reason:

```
{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc \"printf 'hello' > /Users/hmc7279235/Desktop/codex-stream-review-approval-spike-desktop.txt\"","aggregated_output":"","exit_code":null,"status":"declined"}}
2026-09-03T04:59:02.502522Z ERROR codex_core::tools::router: error=exec_command failed for `/bin/zsh -lc "printf 'hello' > /Users/hmc7279235/Desktop/codex-stream-review-approval-spike-desktop.txt"`: CreateProcess { message: "Rejected(\"This action was rejected due to unacceptable risk.\nReason: Automatic approval review failed: We're currently experiencing high demand, which may cause temporary errors.\nThe agent must not attempt to achieve the same outcome via workaround, indirect execution, or policy circumvention. Proceed only with a materially safer alternative, or if the user explicitly approves the action after being informed of the risk. Otherwise, stop and request user input.\")" }
{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Desktop 경로에 `printf 'hello' > …` 셸 쓰기를 실제로 시도했지만, 외부 경로 쓰기 승인 요청이 시스템의 일시적 고수요 오류로 거절되었습니다. 파일은 생성되지 않았습니다."}}
```

Interpretation, carefully: `--approve-for-me` really does route the write through a
separate "automatic approval review" backend (this is a genuine check, not a rubber
stamp — in both live attempts here, the file was **not** created, and the recorded reason
is an explicit failure/deny, not silence). **However, this does not satisfy the design's
goal at all**, for two independent reasons:

1. **Not interceptable or answerable by the calling process.** There is no separate
   "approval-request" event exposed via `--json` stdout or the rollout file for the
   plugin (Claude) to observe and answer — the entire review happens as an opaque,
   fully-automatic internal step inside the `command_execution` item's own lifecycle,
   surfacing only as a terminal `status: "declined"` plus a `codex_core::tools::router`
   stderr-style log line. There is nothing here shaped like `ApplyPatchApprovalParams`/
   `ExecCommandApprovalParams` (the app-server `ServerRequest` types this session
   previously confirmed exist, but only over the blocked RPC socket path) — this is a
   different, CLI/exec-only mechanism, and it gives the caller zero opportunity to
   apply its own judgment per-action, which was the entire point of choosing an
   approval-based model over blanket `read-only` in the first place.
2. **The review backend itself is an external dependency that was actively erroring**
   in this environment both times it was exercised ("We're currently experiencing high
   demand, which may cause temporary errors"). Its fail-safe behavior on that error is to
   deny (good — not a rubber stamp on failure), but this means `--approve-for-me`'s
   reliability is gated on a hosted service's uptime/rate limits, not something local and
   deterministic — a new, unverified failure mode this design would inherit if it
   depended on this flag.

Per the task brief's explicit rule ("If it's a rubber stamp ... do not use
`--approve-for-me`"): it is **not** a rubber stamp, but it is also not usable for this
plugin's actual goal (Claude answering each approval in real time) — there is no answer
surface, and the plugin would just be waiting on an opaque, currently-flaky remote
service instead. Recommend not building on `--approve-for-me` for a different reason than
"rubber stamp": there is no interception point, full stop.

### Conclusion for Task 6

**Outcome (b), precisely characterized**: no approval-request event exists for headless
`codex exec` **or** `codex exec resume` on this CLI version (`0.151.0`) — both
independently live-tested (Steps 3c and 3d), not inferred from `--help` alone — because
there is no approval-*requesting* mode reachable at all for either entrypoint:
`approval_policy` is hardcoded to `"never"` (confirmed directly from `turn_context` in
the rollout file, for both a fresh thread and a resumed one), the `-a/--ask-for-approval`
flag that would set it doesn't exist on `codex exec` or `codex exec resume`, and
`--approve-for-me` substitutes a different, non-interceptable, currently-unreliable
automatic-review mechanism rather than a client-answerable request. Writes/execs outside
the small static `permission_profile` allowlist (workspace root, `/tmp`, `$TMPDIR`) are
hard OS-level denials, immediate, never a hang and never a suspended request.

**Task 6 should drop the "approval-based, not blanket read-only" safety model from the
design doc entirely for v1** — there is no mechanism in this CLI version to build it on.
The realistic choices are: (a) plain `--sandbox workspace-write` with no approval flag,
accepting its small fixed writable-root allowlist (workspace + OS temp dirs) as the
*entire* safety boundary — writes outside it simply fail loudly and immediately, which is
functionally similar to `--sandbox read-only` for anything outside the repo, or (b)
`--sandbox read-only` outright, matching `/cc`'s existing choice. Given `workspace-write`
already restricts to a small explicit allowlist with hard-fail-outside-it semantics and
no way to expand it interactively/approval-based anyway, `workspace-write` (allowing the
reviewer to write findings/notes inside the repo or temp dirs if ever needed) is a
reasonable v1 choice over `read-only` — but the design doc's language about Claude
"evaluating each write/exec attempt in real time" must be removed; that capability does
not exist for this entrypoint.

**Note — this diverges from the task brief's own stated outcome-(b) default.** The
brief's Step 4 says outcome (b) → "Task 6 falls back to `--sandbox read-only`." The
`workspace-write`-with-fixed-allowlist recommendation above is my judgment call, not that
literal default — I'm flagging the divergence explicitly rather than letting Task 5 treat
it as the brief's own conclusion. The reasoning (workspace-write's allowlist is static and
fails just as hard/immediately as read-only for anything outside it, so it costs nothing
extra) seems sound to me, but Task 5 should decide whether to accept it or just follow the
brief's literal `read-only` fallback instead.

**Spike thread IDs created during this investigation** (all under
`~/.codex/sessions/2026/09/03/`, not yet archived/deleted — record for Task 4/5's
cleanup pass once the exact archive/delete CLI semantics are confirmed):
`01a0659e-c295-7e21-ba0d-6234f4c987f4`, `01a0659f-6a55-7340-b539-56a815568dda`,
`01a065a0-3edc-7d90-a6da-d427d6ace1a4`, `01a065a0-e269-7893-bfa5-7673ca9ba6cb`,
`01a065a2-3c73-7af0-b323-57179d2d4b6b`, `01a065a3-55a4-7d73-a7a6-1be8236d39d1`,
`01a065ab-0fdd-7f11-9118-1a66303c430f` (the Step 3d resume-test thread — both round 1 and
round 2 ran against this same thread id). (A seventh attempt with the literal task-brief
flag combination, and an eighth with `--approve-for-me --sandbox workspace-write`
together, both failed CLI argument parsing
before a thread was ever created — no thread ID to record for those two.)

## Task 2 spike result: resume context reuse

**Date:** 2026-09-03. **CLI version:** `codex-cli 0.151.0`. Raw evidence is
embedded directly below, matching Task 1's standard (a fuller narrative
walkthrough also exists at
`.superpowers/sdd/2026-09-03-codex-stream-review/task-2-report.md`, but that
path is gitignored and has no git history — nothing load-bearing in this
section depends on it surviving).

**Setup**: scratch repo with a committed baseline `utils.py::last_index()`
(correct, with an empty-list `ValueError` guard) and an uncommitted diff that
strips the guard and introduces a concrete off-by-one (`return len(lst)`
instead of `return len(lst) - 1`) — checkable answer: line 3, wrong for every
non-empty list (off-by-one), and for an empty list specifically returns `0`
(looks like a valid index) instead of signaling "no last index exists."

**Round 1** (fresh thread): `codex exec --json --sandbox read-only -c
model_reasoning_effort=low "Review the uncommitted diff in this repo for
correctness bugs. Do not fix anything."` — thread `01a065b0-f399-7792-9335-996d27a8811a`.
Codex found the diff itself via `git diff` (never pasted into the prompt),
empirically verified the bug with a `python3 -c` assertion, and correctly
reported it (`"ISSUES:\n\n1. utils.py:3 — last_index() returns len(lst),
which is one past the final valid index. ... It also silently returns 0 for
an empty list instead of raising the documented ValueError."`). Raw final
`token_count` event for this round, from the rollout file
(`grep '"type":"token_count"' <rollout> | grep '"ordinal":48,'`):

```json
{"timestamp":"2026-09-03T05:15:21.385Z","ordinal":48,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":113801,"cached_input_tokens":93904,"cache_write_input_tokens":19879,"output_tokens":917,"reasoning_output_tokens":297,"total_tokens":114718},"last_token_usage":{"input_tokens":19882,"cached_input_tokens":19720,"cache_write_input_tokens":159,"output_tokens":166,"reasoning_output_tokens":85,"total_tokens":20048},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":null,"secondary":null,"credits":null,"individual_limit":null,"spend_control_reached":null,"plan_type":null,"rate_limit_reached_type":null}}}
```

Own-turn total (this is the thread's first turn, starting from 0):
**114,718 tokens** (`total_token_usage.total_tokens`).

**Round 2** (`codex exec resume 01a065b0-... --json "Which specific line
number is the bug on, and why exactly does it cause a wrong result for an
empty input?"`): answered correctly (`"The bug is on utils.py:3: return
len(lst). For an empty list, len(lst) is 0, so the function returns 0. But an
empty list has no elements and therefore no valid index; the prior contract
explicitly raised ValueError. Returning 0 incorrectly presents index 0 as
valid, and any caller that uses it to access lst[0] will then get an
IndexError."`) with **zero `command_execution`/`custom_tool_call` items**.
Exact command run against the round-2 portion of the (shared, resumed) rollout
file, ordinals 49-62:

```bash
awk -F'"ordinal":' '{split($2,a,","); print a[1]" "$0}' "$ROLLOUT" \
  | awk '$1+0 > 48' \
  | grep -c -E '"custom_tool_call|command_execution'
```

Output: `0`. Cross-checked against a full listing of every `"type":"..."`
token in that same ordinal range (`grep -oE '"ordinal":[0-9]+|"type":"[a-zA-Z_]+"'`),
which likewise contains no `command_execution`/`custom_tool_call` entry —
only `event_msg`, `response_item`, `reasoning`, `message`, `token_count`, and
`task_complete`/`task_started` types appear. Codex answered directly from the
resumed thread's own persisted context, with no re-investigation. Raw final
`token_count` event for this round (same rollout file, ordinal 61 — the
thread's second turn):

```json
{"timestamp":"2026-09-03T05:16:04.541Z","ordinal":61,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":135200,"cached_input_tokens":93904,"cache_write_input_tokens":41275,"output_tokens":1129,"reasoning_output_tokens":406,"total_tokens":136329},"last_token_usage":{"input_tokens":21399,"cached_input_tokens":0,"cache_write_input_tokens":21396,"output_tokens":212,"reasoning_output_tokens":109,"total_tokens":21611},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":null,"secondary":null,"credits":null,"individual_limit":null,"spend_control_reached":null,"plan_type":null,"rate_limit_reached_type":null}}}
```

Marginal cost for this round alone (see field-name findings below):
**21,611 tokens** (= 136,329 total-since-thread-start minus Round 1's ending
114,718).

**Round 3** (fresh, non-resumed comparison call, same effort/sandbox, diff
text + the same follow-up question combined into one prompt): Codex *still*
ran `git diff -- utils.py` to re-verify the pasted diff from disk rather than
trusting the prompt text, needed 2 tool-call round-trips (vs Round 1's 5), and
gave the same correct answer (`"ISSUES:\n\n1. utils.py:3 — return len(lst) is
incorrect. For an empty list, len(lst) is 0, so the function returns 0 even
though an empty list has no valid last-element index; it should raise
ValueError as the prior contract required."`). Raw final `token_count` event,
from Round 3's own (fresh, standalone) rollout file:

```json
{"timestamp":"2026-09-03T05:17:40.230Z","ordinal":30,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":58085,"cached_input_tokens":36706,"cache_write_input_tokens":21370,"output_tokens":598,"reasoning_output_tokens":231,"total_tokens":58683},"last_token_usage":{"input_tokens":21373,"cached_input_tokens":19671,"cache_write_input_tokens":1699,"output_tokens":142,"reasoning_output_tokens":71,"total_tokens":21515},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":null,"secondary":null,"credits":null,"individual_limit":null,"spend_control_reached":null,"plan_type":null,"rate_limit_reached_type":null}}}
```

Own-turn total: **58,683 tokens** (`total_token_usage.total_tokens` — this is
a fresh thread's only turn, so cumulative-since-thread-start equals the
turn's own cost here).

**Token-count field, resolved directly from data, not guessed**: every
rollout `event_msg` with `payload.type=="token_count"` carries
`payload.info.total_token_usage` (cumulative for the entire thread since it
started — confirmed strictly increasing across Round 1 → Round 2 on the same
thread: 114,718 → 136,329) and `payload.info.last_token_usage` (delta since
the *immediately preceding* `token_count` event, i.e. **per individual model
API call, not per full turn** — a multi-tool-call turn like Round 1 or 3 emits
several of these, none individually equal to the turn's total cost). The
`--json` stdout stream's `turn.completed.usage` field is identical to that
turn's ending `total_token_usage` — which means **for `codex exec resume`,
`turn.completed.usage` is cumulative across the whole thread, not that
round's marginal cost**; a caller must subtract the previous round's ending
`total_token_usage` to get the true per-round cost (Round 2's diffed marginal
cost of 21,611 happens to equal its own final `last_token_usage.total_tokens`
only because that particular turn consisted of exactly one model API call —
this equality does not generalize to a resumed round that needs tool calls).

**Headline comparison (the brief's specific ask, Round 2 vs Round 3): resume's
follow-up cost 21,611 tokens vs 58,683 tokens for a fresh call re-establishing
context and asking the same question — resume is ~2.7x cheaper (~63%
reduction) for the follow-up round alone.** This directly confirms the design
doc's per-round token-efficiency goal for a follow-up round, with real
measured numbers.

**Important caveat — do not over-generalize to "resume always wins":**
summing Round 1 + Round 2 (full two-step conversation via resume) = 136,329
tokens, which is *more* than Round 3 alone (58,683 tokens) achieving both the
review and the follow-up answer in a single call. This is a confound, not
evidence against resume: Round 1's prompt forced Codex to *discover* the diff
itself (5 `command_execution` tool calls — reading two full skill files, `git
status`/`diff`, `nl`/`rg`, a failed `python` call, then a `python3 -c`
assertion — plus a 6th, final model call that synthesized the answer; 6 total
model-API completions, matching the 6 `token_count` events observed in Round
1's rollout portion — "6 model-call round-trips" and "5 tool-call
round-trips" in this doc/report refer to these two different counts, not a
discrepancy), a fundamentally more expensive task than Round 3's prompt,
which handed Codex the diff text directly. **The valid, uncontaminated
comparison is Round 2 vs Round 3** (identical follow-up question, one via
resume, one via a fresh call bearing equivalent context) — that comparison
cleanly favors resume. **Untested generalization, stated here as an inference
and not established fact**: a production caller (like `/cc` today) that
already embeds the diff text on round 1 rather than asking Codex to discover
it would *likely* not pay Round 1's inflated investigation cost — this
session's evidence suggests the Round-2-vs-3-style comparison is the more
appropriate one to generalize from, not the raw 1+2-vs-3 sum, but this was
never independently verified with a 4th run (a lean, diff-embedded Round-1
prompt, then resumed for the follow-up). Task 5/future readers should treat
this specific generalization as plausible-but-unverified, not confirmed.

**A second, uncontaminated piece of evidence for resume's efficiency**: a
fresh thread's first turn re-pays a large fixed "session bootstrap" cost that
a resumed turn does not. Extraction command (run against each `response_item`
of `payload.type=="message"` at the given ordinal, printing the length of
each `content[].text`):

```bash
grep "\"ordinal\":$ORD," "$ROLLOUT" | python3 -c "
import json,sys
d=json.loads(sys.stdin.readline())
for c in d['payload'].get('content', []):
    t = c.get('text', '')
    print(f'ordinal $ORD: len={len(t)} first60={t[:60]!r}')
"
```

Literal output, Round 1's fresh-turn system-injected items (ordinals 2-5,
before the actual review prompt at ordinal 10):

```
ordinal 2: len=19621 first60='<skills_instructions>\n## Skills\nA skill is a set of local in'
ordinal 2: len=341 first60='<permissions instructions>\nFilesystem sandboxing defines whi'
ordinal 2: len=1014 first60='<plugins_instructions>\n## Plugins\nA plugin is a local bundle'
ordinal 3: len=2264 first60='You are `/root`, the primary agent in a team of agents colla'
ordinal 4: len=271 first60='<multi_agent_mode>Any earlier instruction enabling proactive'
ordinal 5: len=5640 first60='# AGENTS.md instructions\n\n<INSTRUCTIONS>\n# Codex Global Cont'
ordinal 5: len=457 first60='<environment_context>\n  <cwd>/private/tmp/codex-resume-spike'
```

Sum: 19621+341+1014+2264+271+5640+457 = **29,608 characters** of
system/environment boilerplate before Round 1's actual review prompt.

Same extraction against Round 2's resumed-turn system-injected items
(ordinals 53-54, before the follow-up question at ordinal 55):

```
ordinal 53: len=198 first60='Safe read-only bash commands (ls, cat, grep, find, pwd, curl,'
ordinal 54: len=5229 first60='PONYTAIL MODE ACTIVE — level: full\n\n# Ponytail\n\nYou are a l'
```

Sum: 198+5229 = **5,427 characters** — roughly 5.5x less repeated boilerplate
than Round 1's fresh-turn bootstrap, on the same machine, same environment,
same session. This is genuine resume-specific savings, independent of the
diff-investigation confound above.

**Environment-specific caveat**: this machine's own `AGENTS.md`-driven
mandatory skill-injection behavior (`using-superpowers` requires invoking a
skill "before ANY response," causing Codex to read the `using-superpowers`
and `ponytail` skill files in full on Rounds 1 and 3) added real but
environment-specific overhead not inherent to Codex itself — a differently
configured environment (e.g. a CI runner without personal `AGENTS.md`/plugin
skills) would likely show smaller absolute token figures across all three
rounds, though the *relative* resume-vs-fresh comparisons above should still
hold in direction if not exact magnitude.

**Spike thread IDs created during this investigation** (not yet
archived/deleted — record for Task 4/5's cleanup pass): `01a065b0-f399-7792-9335-996d27a8811a`
(Round 1 + Round 2, resumed), `01a065b3-5637-7c31-90ba-ff4bf99cf8e4` (Round 3,
fresh/standalone). Scratch repo and all `/tmp/resume-spike-*` files were
deleted after capturing the evidence above.
