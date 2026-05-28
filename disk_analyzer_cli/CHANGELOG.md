## 1.1.0

**Performance**

- **disk_analyzer_cli**: add native `readdir()`/`fstatat()` traversal on macOS and Linux for much faster scans.
- **disk_analyzer_cli**: reuse native stat/path buffers during scans to reduce allocation overhead.
- **disk_analyzer_cli**: add scan benchmarks with ncdu comparisons and real-directory targets.

**Features**

- **disk_analyzer_cli**: add `scan --batch-size` for tuning SQLite write batches.

## 1.0.1

**Bug Fixes**

- **disk_analyzer_cli**: enhance index creation for entries to improve query performance

## 1.0.0

- Initial version of the project.
