# Scan Benchmarks

This directory contains a small benchmark harness for comparing `disk_analyzer_cli`
scan performance with `ncdu` scan/export modes.

The harness generates deterministic fixture directories, runs each benchmark target
for a configurable number of iterations, and writes both JSON and Markdown reports.
Generated fixtures and results are ignored by git.
Temporary benchmark databases and CLI home directories are created under
`benchmark/.tmp` by default so benchmarking `/tmp` does not measure the
benchmark's own scratch files.

## Quick Start

```bash
dart run benchmark/scan_benchmark.dart --iterations 1 --profiles smoke
```

That command runs:

- `scanner-only`: in-process `DiskScanner.scan`, without SQLite.
- `app-sqlite`: in-process scanner plus `DiskDatabase.batchWriter`.
- `cli-dart-run`: `dart run bin/disk_analyzer_cli.dart scan`, with a temporary `HOME`.
- `ncdu-json-t<N>`: `ncdu --ignore-config -0 -x --threads N -o /dev/null`.
- `ncdu-bin-t<N>`: `ncdu --ignore-config -0 -x --threads N -O /dev/null`.

If `ncdu` is not installed, the ncdu rows are marked as skipped and the local
benchmarks still run.

## Useful Runs

```bash
# Compare small and medium generated fixtures.
dart run benchmark/scan_benchmark.dart \
  --profiles smoke,mixed \
  --iterations 5

# Test SQLite transaction batch sizes.
dart run benchmark/scan_benchmark.dart \
  --profiles mixed \
  --iterations 5 \
  --batch-size 50000

# Compare against ncdu single-thread and 8-thread scans.
dart run benchmark/scan_benchmark.dart \
  --profiles wide,mixed \
  --iterations 5 \
  --ncdu-threads 1,8

# Benchmark a real directory such as /tmp.
dart run benchmark/scan_benchmark.dart \
  --profiles '' \
  --paths /tmp \
  --iterations 3 \
  --ncdu-threads 1,8

# Regenerate fixture directories from scratch.
dart run benchmark/scan_benchmark.dart \
  --profiles smoke,wide,deep,mixed,hardlinks \
  --recreate-fixtures
```

## Fixture Profiles

- `smoke`: tiny tree for validating the harness.
- `wide`: many sibling directories and small files.
- `deep`: a long single-child directory chain.
- `mixed`: several levels with varying file sizes.
- `hardlinks`: small tree plus hardlinks created with `ln` on macOS/Linux.

The fixtures are intentionally synthetic. They are good for tracking regressions
and isolating scanner overhead, but they are not a substitute for running the
same benchmark on a real project tree.

Use `--paths` to benchmark existing directories. Path targets are named from
their absolute path in reports, so `/tmp` appears as `tmp`.

## Notes On Fairness

The `scanner-only` target measures traversal and stat overhead without storage.
The `app-sqlite` target measures the same scan path plus SQLite writes while
avoiding Dart process startup. The `cli-dart-run` target includes CLI startup and
argument parsing, so compare it separately from the in-process targets.

The ncdu commands use `-0` to suppress UI work, `-x` to stay on one filesystem,
and export to `/dev/null` so the benchmark measures scan/export cost rather than
interactive browsing. `-O` is ncdu's binary export format, which is the better
comparison point for multi-threaded scans in ncdu 2.x.

On macOS and most developer machines, this harness does not attempt to flush the
filesystem cache. Treat the default results as warm-cache medians.