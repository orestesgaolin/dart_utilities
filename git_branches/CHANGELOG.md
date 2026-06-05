## 0.2.0

**Features**
- detect squash- and rebase-merged branches (which `git branch --merged` misses) via a patch-id check, shown with a `squashed` badge and treated as safe-to-delete; results are cached per branch/base tip so reloads stay fast.
- the UI now paints the branch list immediately from reachability and fills in squash-merge detection in the background.

## 0.1.0

- Initial version of the project.

**Features**
- interactive nocterm UI listing local branches with merge state, staleness, and upstream status, ordered by last activity.
- triple-state batch marking (none → delete → push) with a single confirmed apply, plus quick `d`/`p` actions on the highlighted branch.
- local-only delete (`-d` for merged, `-D` with extra confirmation for unmerged); push with automatic `-u origin <branch>` when no upstream exists.
- sort (stalest / recent / name) and filter (all / merged / unmerged) toggles; current and default branches are protected.
- `list` command for plain-text output (`--merged`, `--stale`).
- `demo` command building a self-contained repo with a local remote and a realistic mix of branches, no network required.
