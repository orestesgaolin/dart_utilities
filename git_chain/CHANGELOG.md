0.5.0

Features

- add git_chain cli


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
