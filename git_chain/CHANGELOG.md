## 0.5.5

**Features**

- **git_chain**: add conflict demo and improve TUI sync handoff


## 0.5.5

**Features**
- `git_chain demo --conflict` seeds a real merge conflict on `lib/app.dart`, so syncing the demo's `feat/polish` chain exercises the conflict → merge-tool handoff.

## 0.5.4

**Bug Fixes**
- stop stray characters (e.g. `62;22c`) leaking into the shell after the TUI exits. nocterm sends a Device Attributes query (`ESC[c`) on shutdown and closes stdin; we now flush the controlling terminal's input via a fresh `/dev/tty` handle (fd 0 is gone by then) so the query's reply is discarded instead of landing at your shell prompt.

## 0.5.3

**Bug Fixes**
- fix a `StdinException: Bad file descriptor` crash when a TUI sync hit a conflict and handed off to the shell. stdin can't be read synchronously after a nocterm session, so the shell run no longer prompts: the stash/keep-changes decision made in the TUI is passed through, and conflict continuation is detected automatically after `git mergetool`. The CLI `sync` command still prompts as before.

## 0.5.2

**Features**
- chain detail marks the currently checked-out branch with a `*`, and the marker updates immediately after a checkout (the view refreshes).
- checking out a branch with a dirty tree now offers a choice: stash & restore, check out keeping the changes (no stash), or cancel.
- syncing with a dirty tree offers the same choice: stash & restore, sync without stashing (keep changes), or cancel. Merges with unrelated uncommitted files proceed; rebase still reports git's clean-tree requirement.

## 0.5.1

**Bug Fixes**
- syncing from the TUI no longer fails outright when the working tree is dirty (e.g. uncommitted editor/config changes): it now detects this upfront and offers to stash and restore around the sync, matching the shell path.
- clarified that branches containing merge commits rebase correctly — git drops the merges and replays only the real commits onto the parent (verified by tests).

## 0.5.0

**Features**
- syncing from the TUI now runs in place with a live progress overlay; the app stays open for conflict-free rebases/merges instead of dropping to the shell.
- a sync only hands off to the shell when a branch actually conflicts (so `git mergetool` can run); already-synced branches are skipped on the shell re-run.

## 0.4.1

**Bug Fixes**
- fix syncing from the TUI doing nothing / appearing to freeze: triggering a sync stopped the UI through a path that called `exit()`, so the handoff that runs the sync never executed. The UI now releases the terminal cleanly, runs the sync (with output and `git mergetool`), and exits.
- run git with `GIT_TERMINAL_PROMPT=0` so a missing/unauthenticated remote makes `fetch` fail fast instead of hanging on a credential prompt.
- `git_chain demo` now keeps its PR fixture out of git (via `.gitignore`) so the working tree is clean and sync doesn't prompt to stash.

## 0.4.0

**Features**
- add `git_chain demo` to build a self-contained repo with dummy stacked branches and a local PR fixture for screenshots/exploration — no GitHub calls.
- read PRs from a `.git_chain_prs.json` fixture in the repo root when present (used by `demo`, offline-friendly).

## 0.3.0

**Features**
- when the working tree is dirty, checkout and sync offer to stash changes and automatically restore them afterwards.
- stashes are created with an explicit `git_chain: <reason> @ <timestamp>` label so they're easy to find and recover; a conflicting auto-restore keeps the named stash.

## 0.2.0

**Features**
- cache branch status and PRs per session so revisiting a chain is instant and refreshes in the background.
- skip single-branch chains during detection by default (`minStackSize`).
- expand a branch (`e`) to list its commits vs. its parent, excluding merges.
- checkout the selected branch (`c`) directly from the chain detail view.
- show PR assignees next to each branch.
- left-align and trim chain/branch names to fixed-width columns.
- show "Loading…" instead of "(no PR)" until status/PRs have loaded.

**Bug Fixes**
- transient status messages (e.g. "Opening PR…") now clear themselves.
- keep chain ordering stable between visits (order by creation, not last update).

## 0.1.0

- Initial version of the project.

**Features**
- visualize stacked branch chains and their GitHub PRs in an interactive nocterm TUI.
- hybrid chain detection: reconstruct chains from open PR base/head graphs, with manual persistence and PR re-annotation.
- synchronize a chain to its latest target branch via cascading rebase or merge (chosen per run).
- open conflicts in the configured `git mergetool`, then continue or abort the chain.
- track repositories, chains, and full sync history across machines in `~/.git_chain/git_chain.db`.
- `scan`, `list`, `sync`, and `tui` CLI commands (`tui` is the default).
