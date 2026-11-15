# AGENTS.md — local law for agents working in eservo

This file adds repo-local rules on top of the Owner's GLOBAL AGENTS.md
(the copy in agent-team-ci).  Where the two disagree, the GLOBAL file
wins.

## Identity law (same as global)

- Commit author: `MODEL <MODEL@PROVIDER>` (e.g.
  `GLM-5.3 <glm-5.3@z.ai>`).  Never a harness/container identity
  ("Z User", "Claude Sonnet", bot names) — that leak happened to this
  repo's first drafts and was rewritten before the first push; do not
  reintroduce it.
- Both trailers on every commit:
  `Co-authored-by: Z.ai agent <agent@chat.z.ai>` and
  `Co-authored-by: Khalid Rafi <khaalidrafi@gmail.com>` (relay identity
  corrected 2026-11-15; the old z.ai-agent form is retired).
- Never commit directly to `main`.  Work lands on `ai/main`; use
  `ai/<topic>` branches for long work.  Small, single-purpose commits
  with messages that explain the algorithm, not just the diff.

## Repo rules

- Pure Elisp + child processes only: no external Emacs packages, no
  xwidgets/GUI deps.  eservo must keep running on Linux, TTY and
  Android/Termux unchanged (Owner priority order).
- Embedded-engine exception (Owner order, Discord 2026-11-15): eservo
  IS an embedded browser — the servo engine may be linked into the
  Emacs process through the optional libeservo dynamic module
  (native/, eservo-embedded.el, docs/EMBEDDED-SERVO.org).  The core
  law stands around it: the Elisp layer stays pure, the module is
  OPTIONAL (every op degrades to a clear install hint without it),
  and `make compile` / `make test` must stay green on machines with
  no Rust toolchain.  Rust changes land only through the native.yml
  lanes; the servo crate version is pinned and upgrades go through
  the pin job, never blind.
- The backend op set (eservo-backend.el defstruct) stays SMALL.  A new
  capability must fit an existing op or argue hard for a new one.
- Secrets law: human credentials via `auth-source` only; session files
  are credentials (0600/0700, under `eservo-state-dir`, never in the
  repo); never print, log or echo a secret.  Before adding any command
  that touches credentials, extend AI-REVIEW.org's secrets section.
- Tests are offline and deterministic: stub the backend, never hit a
  network or a device from ERT.  `make test` must stay green and
  `make compile` warning-free (warnings are errors) before any commit.
- Update AI-REVIEW.org whenever a unit lands: evidence packet first
  (tests/compile results), then the review-queue entries a human
  should read.  The Owner reviews asynchronously — the file IS the
  handoff.
- Bug classes to watch (all bit us once, all pinned by tests): match
  data clobbering across helper `string-match` calls; empty strings
  being truthy in `or`; `apply` spreading a list meant as one
  argument.
