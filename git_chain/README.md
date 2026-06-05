# git_chain

A terminal UI to manage **stacked git branch chains** - when one feature spans
several PRs that each target the previous branch:

```
main ← feat/api-layer ← feat/ui-widgets ← feat/polish
```

Visualize the chain and its GitHub PRs, synchronize the whole stack to the latest
target branch (cascading rebase or merge), resolve conflicts in your merge tool,
and keep history across every repo on your machine.

<img src="https://raw.githubusercontent.com/orestesgaolin/dart_utilities/refs/heads/main/git_chain/doc/chain_detail.png" alt="Chain detail" width="800">

## Features

- Visualize stacked branches with their PR number, assignee, draft flag, and live `behind` / `ahead` status.
- Sync a chain to its target — cascading **rebase** or **merge**, running in-app with a live progress overlay.
- Conflicts open in your configured **`git mergetool`**, then the sync continues.
- Stash prompt with explicit, named stashes (auto-restored) when the tree is dirty.
- Tracks repos, chains, and full sync history in `~/.git_chain/git_chain.db`.
- Hybrid chain detection: reconstructs chains from open PRs (`gh`), editable per repo.

## Install

### Pub.dev

```sh
dart pub global activate git_chain
```

Or from a local checkout:

```sh
dart pub global activate --source=path <path to this package>
```

### Homebrew

```sh
brew tap orestesgaolin/tap
brew install git_chain
```

(macOS arm64 and Linux x64.)

**Requires:** `git`, and [`gh`](https://cli.github.com) authenticated (`gh auth login`) for PR detection.

## Usage

Run inside any git repo:

```sh
git_chain          # interactive TUI (default)
git_chain scan     # import chains from open PRs
git_chain list     # plain-text repos/chains with status
git_chain sync [name] -s rebase|merge   # sync from the shell
```

### Keys (TUI)

| Key         | Action           | Key | Action                     |
| ----------- | ---------------- | --- | -------------------------- |
| `↑↓`        | move             | `s` | sync (choose rebase/merge) |
| `⏎` / `→`   | open             | `e` | expand commits vs. parent  |
| `←` / `esc` | back             | `c` | checkout branch            |
| `i`         | import from PRs  | `o` | open PR in browser         |
| `d`         | delete / untrack | `h` | sync history               |
| `r`         | refresh          | `q` | quit                       |

## Screenshots

| Chains                                                                                                                          | Stack status                                                                                                                              |
| ------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| <img src="https://raw.githubusercontent.com/orestesgaolin/dart_utilities/refs/heads/main/git_chain/doc/chains.png" width="420"> | <img src="https://raw.githubusercontent.com/orestesgaolin/dart_utilities/refs/heads/main/git_chain/doc/expanded_commits.png" width="420"> |

| Choose strategy                                                                                                                   | Live sync                                                                                                                              |
| --------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| <img src="https://raw.githubusercontent.com/orestesgaolin/dart_utilities/refs/heads/main/git_chain/doc/strategy.png" width="420"> | <img src="https://raw.githubusercontent.com/orestesgaolin/dart_utilities/refs/heads/main/git_chain/doc/sync_progress.png" width="420"> |

## Try it

Build a self-contained demo repo (dummy branches + a local PR fixture, no GitHub):

```sh
git_chain demo && cd ~/.git_chain/demo-repo && git_chain
```

Add `--conflict` to seed a real merge conflict so syncing the `feat/polish`
chain hits your git mergetool (set one first, e.g.
`git config --global merge.tool opendiff`):

```sh
git_chain demo --conflict
```

## How sync works

Pulls the latest target, then cascades: rebase/merge `feat/1` onto the updated
`main`, `feat/2` onto the updated `feat/1`, and so on. It runs in the TUI; only
when a branch actually conflicts does it hand off to your shell for `git
mergetool`, then you run `git_chain` again to return. Rebase rewrites history, so
expect to force-push (`--force-with-lease`).
