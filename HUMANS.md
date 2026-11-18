# HUMANS.md

A guide for human developers who did not write this code. Written from a
fresh read of the sources on 2026-11-18, per the Owner's order that
agents explain AI-generated codebases to humans.

## What this is

eservo drives a web browser from Emacs. You get small interactive
commands (`eservo-goto`, `eservo-snapshot`, `eservo-click`, ...), a
deterministic script runner with no AI in the loop
(`eservo-script-run`), and `eservo-agent-brief`, which prints the whole
tool menu plus the live page snapshot so an external LLM can drive the
browser by naming the next command.

There are four backends behind one command set: `cdp` (default;
Chromium/Chrome over the DevTools Protocol), `servo` (the Servo engine
over its Firefox-RDP devtools server, launched or attached), `adb`
(best effort; an Android device browser driven with `adb shell`), and
`embedded` (the Servo engine linked inside the Emacs process through
the optional `libeservo` dynamic module in `native/`).

The core is pure Elisp plus child processes: no external Emacs
packages, no xwidgets, no GUI libraries. Minimum Emacs is 27.1. The
goal is that the same commands run on Linux desktop, from `emacs -nw`
on a TTY, and on Android/Termux. The single sanctioned exception to
"pure Elisp" is the Rust module for the embedded backend, which is
optional; every op degrades to a clear install hint without it.

## Mental model

One driver, one backend struct, many transports.

- `eservo.el` holds `eservo--current-driver`, the single live browser
  session. `eservo-start` builds it, `eservo-stop` clears it. Starting
  a second browser while one is alive is an error, not a replace.
- A backend is an `eservo-backend` struct (defined in
  `eservo-backend.el`) whose slots are functions: one slot per op
  (`goto`, `snapshot`, `fill`, `click`, `keys`, `wait`, `extract`,
  `screenshot`, `evaluate`, `cookies-get`, `cookies-set`, `start`,
  `stop`, `alive-p`, `url`). A backend that cannot do an op leaves the
  slot nil, and `eservo-backend-call` turns that into a clear error.
- Interactive commands, the script runner, and the session code all go
  through `eservo-backend-call`. None of them know which transport is
  underneath.
- Backend files load on demand: `eservo-backend-make` requires
  `eservo-<name>` only when that backend is picked.
- The page-facing vocabulary is the snapshot: a compact text outline
  where interactive elements carry `[N]` refs. The refs are real
  `esvref="N"` attributes stamped into the live DOM (cdp and servo
  backends) or remembered index/bounds pairs in driver state (adb).
  `click` consumes those refs.

Data flow for a typical op, cdp backend:

    M-x eservo-click RET 7
      -> eservo.el: eservo-backend-call driver 'click 7
      -> eservo-cdp.el: eservo-cdp--click builds JS targeting
         [esvref="7"], calls eservo-cdp--evaluate
      -> eservo-cdp--rpc: JSON-RPC over eservo-ws (pure Elisp
         WebSocket) to the browser's page target
      -> Chromium runs the JS, returns a value, the RPC loop wakes up.

## Code map

| File / symbol | Role |
|---|---|
| `eservo.el` | Interactive commands, `eservo-agent-brief`, holds `eservo--current-driver`. |
| `eservo-backend.el` | `eservo-backend` op struct, `eservo--driver` struct, backend registry, `eservo-backend-call` dispatch, `eservo-state-dir` (XDG_STATE_HOME or ~/.local/state, then `eservo/`). |
| `eservo-ws.el` | Minimal RFC 6455 WebSocket client: handshake, client masking, frame encode/parse, fragmentation, ping/pong, close. Used by cdp. |
| `eservo-rdp.el` | Firefox Remote Debugging Protocol client over plain TCP, `length:JSON` framing, reply matching by `from` actor. Used by servo. |
| `eservo-cdp.el` | Default backend. Launches Chromium with `--remote-debugging-port=0`, scrapes the port from the "DevTools listening on" stderr line, finds the page target via `http://127.0.0.1:PORT/json`, then JSON-RPC over the WebSocket. |
| `eservo-servo.el` | Servo backend: launch from PATH or attach by `eservo-servo-port`; every page op runs as JS via the console actor's `evaluateJS`. Also the Android on-device lane (`eservo-servo-android-start`) that starts the servo APK with a `servoargs` `--devtools=PORT` intent extra. |
| `eservo-adb.el` | Android backend: `uiautomator dump` snapshot, `input tap/text/keyevent`, `screencap`. No DOM ops. |
| `eservo-session.el` | Per-site login persistence: `eservo-session-save/load/login`; `eservo-credentials` reads auth-source and never prints. |
| `eservo-script.el` | Script parser (one sexp list, or Org/plain one step per line) and the step runner. |
| `eservo-embedded.el` | Backend mapping the op set onto `eservo-embedded-module-*` primitives; module search and load. |
| `native/src/lib.rs` | Module entry (`emacs_module_init`), defines the `eservo-embedded-module-*` primitives, panic containment via `catch_unwind`. |
| `native/src/engine.rs` | Engine thread + mpsc request/reply plumbing; `ReqOp`/`Reply`/`Msg`; stub engine when built without the `servo` feature. |
| `native/src/servo_glue.rs` | The real servo embedding (only compiled with `--features servo`). |
| `native/src/emacs_api.rs` | Raw Emacs module C API bindings used by the above. |
| `tests/run.el` | Test runner: loads `tests/test-helpers.el`, then every `tests/test-*.el`, then `ert-run-tests-batch-and-exit`. |
| `tests/test-helpers.el` | In-process fake HTTP and fake WebSocket servers, so tests need no browser, device, or network. |
| `AGENTS.md`, `AI-REVIEW.org`, `CHARTER.org`, `WORKFLOW.org`, `ROADMAP.org`, `docs/EMBEDDED-SERVO.org` | Repo law, review queue, scope, workflow, embedded-engine design. Read `AGENTS.md` before committing. |

## Core algorithms

Backend dispatch. `eservo-backend-call` (eservo-backend.el) reads the op
slot with the generated accessor `eservo-backend-<op>`, errors if nil
("backend `X' does not support `Y'"), else applies the function to the
driver and args. There is no generic method system; a struct of
functions is the whole mechanism.

WebSocket framing (eservo-ws.el). `eservo-ws--read-frames` is an
incremental parser over a unibyte buffer: it peels complete frames and
returns `(FRAMES . REST)` so partial bytes wait for the next chunk. It
handles 7-bit inline lengths, 16-bit extended, and 64-bit extended
(parsing the 64-bit form but erroring on frames over 100 MiB).
`eservo-ws--unmask` XORs payload bytes with the 4-byte key; clients
must mask, servers must not, and the same XOR is used in both
directions (`eservo-ws--frame` with mask `'client` generates a random
key). Fragmented messages accumulate in the `fragment` slot until a
FIN frame arrives. Handshake: send the upgrade request, wait for
`HTTP/1.1 101` and a matching `Sec-WebSocket-Accept` (SHA-1 of key +
the RFC 6455 GUID, base64) with a 10 s default timeout.

CDP JSON-RPC correlation (eservo-cdp.el). `eservo-cdp--rpc` bumps
`next-id`, puts a `(:done nil :result nil :error nil)` plist into a
hash table keyed by id, sends, then loops `accept-process-output` in
0.1 s slices until the WebSocket callback (which runs in the process
filter) sets `:done`. Timeout is `eservo-cdp-timeout` (30 s default).
Events (messages with `method`, no `id`) are ignored; waits are done
by polling the page, keeping the state machine trivial.

Snapshot refs. One JS IIFE (`eservo-cdp--snapshot-js`,
`eservo-servo--snapshot`) runs `querySelectorAll` over a selector list
of interactive elements, skips zero-size elements, stamps each with
`esvref="N"`, and returns one line per element, `[N] tag "label"`,
capped at `eservo-cdp-max-elements` / `eservo-servo-max-elements`
(250). `click` with a number targets `[esvref="N"]` in the live DOM.
This is why a snapshot must be retaken after navigation: the stamped
attributes die with the old document.

React-safe fill. Setting `el.value` directly does not notify React or
Vue, which is exactly the chat-input case eservo targets. Both the cdp
and servo backends use the native prototype setter
(`Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,
"value").set`) and then dispatch bubbling `input` and `change` events.
Non-input elements fall back to setting `textContent`.

RDP framing and actor matching (eservo-rdp.el). Packets are
`<byte-length>:<JSON>`. The filter only accumulates; parsing moves
complete packets from an accumulation buffer into a reply queue. RDP
has no request ids, so replies are matched by their `from` actor only,
and the client keeps one outstanding request per actor. Unsolicited
packets live in a queue bounded at 100 (`eservo-rdp--queue-max`) and
are silently dropped past that. Callers can pass a `match` predicate
to skip unrelated packets from the same actor.

adb snapshot (eservo-adb.el). `uiautomator dump` writes XML to
`/sdcard/eservo-uidump.xml`; `eservo-adb--parse-nodes` scans `<node
...>` tags with `string-match`, keeps nodes that are clickable or have
non-empty text/content-desc, parses `[x1,y1][x2,y2]` bounds, and
records `(index bounds text)` triples in driver state. Taps go to the
bounds center via `input tap`.

Script runner (eservo-script.el). `eservo-script--parse` decides the
flavor by the first non-comment character: `(` means read sexps (a
single list-of-lists unwraps to its steps), anything else means read
one sexp per line, skipping Org bullets and headings. The runner
dispatches with `pcase` over 14 step types (`goto wait sleep fill
fill-secret click keys extract screenshot session-load write echo
stop`), collects `(OP . RESULT)` pairs, and tracks the last `extract`
for `write`. `fill-secret` pulls the password from auth-source at run
time so it never appears in the script or the step log.

Native engine thread (native/src/engine.rs). Every Elisp-visible op is
a synchronous `Msg::Call` sent through an mpsc channel to a single
engine thread that alone owns the servo instance; servo's
`EventLoopWaker` wakeups arrive as `Msg::Wake` on the same channel so
`spin_event_loop` runs on the engine thread. A global
`Mutex<Option<EngineHandle>>` holds the engine; `catch_unwind` wraps
op bodies so a Rust panic becomes an Elisp error instead of an Emacs
crash. Without the `servo` cargo feature the thread is a stub that
answers every op with a not-linked error; that stub is the ABI surface
the fast CI lane loads into real Emacs.

## Invariants and gotchas

- One live driver. `eservo-start` errors if a driver is alive. Run
  `eservo-stop` before switching backends.
- The op set stays small on purpose (AGENTS.md). A new capability must
  fit an existing op slot or argue hard for a new one.
- Secrets: session files ARE credentials (cookies + storage tokens),
  written 0600 into a 0700 dir under `eservo-state-dir`, never inside
  the repo. Human credentials come from auth-source only. Never print,
  log, or echo them. `eservo-script` logs only op names for this
  reason.
- Scripts are not sandboxed. They run as your Emacs user with your
  credentials. Only run scripts you have read.
- Known Elisp bug classes that already bit this repo once each
  (AGENTS.md, pinned by tests): helper `string-match` calls clobbering
  the caller's match data (see the comment in
  `eservo-adb--parse-nodes`); empty strings being truthy in `or` (see
  `eservo-adb--xml-attr-nonempty`); `apply` spreading a list that was
  meant as one argument.
- Snapshot refs are volatile. They are DOM attributes (cdp/servo) or
  cached bounds (adb) tied to the current page; retake the snapshot
  after any navigation.
- Backend-specific limits, all deliberate and surfaced as clear
  errors: adb has no DOM (no `extract`/`evaluate`/cookies, `fill`
  accepts only `text=...` selectors, `input text` cannot type quotes
  and sends spaces as `%s`); servo has no screenshots or cookie ops
  over RDP and its `keys` are untrusted synthetic JS events (prefer
  `fill`); embedded v0 only boots, navigates, reports the URL, and
  resizes when servo-linked, and every other op fails with an error
  naming `docs/EMBEDDED-SERVO.org`.
- The WebSocket client speaks plain `ws://` only (no TLS), never
  negotiates permessage-deflate, and errors on frames over 100 MiB.
- Stop semantics: a backend only kills a browser process it launched.
  Attach modes (`eservo-cdp-port`, `eservo-servo-port` set) leave the
  target running on `eservo-stop`. A hard Emacs kill can orphan a
  launched Chromium (noted in AI-REVIEW.org).
- `make compile` and `make test` must stay green on machines with no
  Rust toolchain; the Elisp layer never requires the module.
- Commit identity law (AGENTS.md): author is the model, never a
  harness identity; both co-author trailers on every commit; never
  commit to `main`.

## Developing

Build and test (from the Makefile and CI):

    make compile   # byte-compile all sources, warnings are errors
                   # (byte-compile-error-on-warn t)
    make test      # emacs --batch -l tests/run.el; all tests offline
    make clean     # remove .elc files

Tests: 85 `ert-deftest` forms across 9 `tests/test-*.el` files
(counted; the README's "82" has drifted). None of them need a browser,
a device, or a network; backends are stubbed or faked in-process.

CI (`.github/workflows/ci.yml`) runs `make compile` then `make test`
on Emacs 31.1 built from the upstream GNU tarball
(`.github/actions/setup-emacs-gnu`, sha256 pinned).
`.github/workflows/native.yml` has two lanes for the module: `module`
(zero-dependency build, loaded into a real Emacs 31.1; must stay
green) and `servo` (`cargo build --release --features servo` against
servo =0.8.0, `continue-on-error: true` while the API pin settles).

Native module, built locally from `native/`:

    cargo build --release                    # zero-dep ABI module
    cargo build --release --features servo   # link the real engine

Branch law: work lands on `ai/main`; use `ai/<topic>` branches for
long work; never commit directly to `main`; no force-push, no history
rewrite once reviewed. Update `AI-REVIEW.org` whenever a unit lands:
evidence packet first, then review-queue entries for the human.
