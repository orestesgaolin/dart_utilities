## 1.1.2

- fix treemap viewer

## 1.1.1

Features

- add treemap viewer
- disk_analyzer_cli: treemap shortcuts + rescan size tests
- disk_analyzer_cli: left/right arrow navigation in list view


## 1.1.0

**Performance**

- add native `readdir()`/`fstatat()` traversal on macOS and Linux for much faster scans.
- reuse native stat/path buffers during scans to reduce allocation overhead.
- add scan benchmarks with ncdu comparisons and real-directory targets.

**Features**

- add `scan --batch-size` for tuning SQLite write batches.
- edit ignored folders in tui

## 1.0.1

**Bug Fixes**

- enhance index creation for entries to improve query performance

## 1.0.0

- Initial version of the project.
