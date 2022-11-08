## changelog_cli

CLI to generate an opinionated changelog.

<img src="https://raw.githubusercontent.com/orestesgaolin/dart_utilities/main/changelog_cli/example/screenshots/changelog_cli.png?token=GHSAT0AAAAAABWNHNTSBEDP4XHYYR5P6SSSY3GKMBQ" alt="Example usage screenshot" width="600">

By default it just generates the changelog based on the whole git history. You can pass custom `--start` and `--end` parameters which are git refs to get a subset of changes between two commits or tags. That was my main goal with this CLI as it doesn't necessarily require semantic versioning.

---

## Getting Started 🚀

If the CLI application is available on [pub](https://pub.dev), activate globally via:

```sh
dart pub global activate changelog_cli
```

Or locally via:

```sh
dart pub global activate --source=path <path to this package>
```

## Usage

```sh
changelog_cli generate

# or
changelog_cli generate --path ~/Projects/my-app --start 1.0.0 --end 1.1.0 --version 1.1.0 --limit 2000 --printer markdown
```

You can get the previous tag using git command and then pass it to `changelog_cli`:

```sh
git describe --tags --abbrev=0
changelog_cli generate --start changelog_cli-v0.0.2
```

## Running Tests with coverage 🧪

To run all unit tests use the following command:

```sh
$ dart pub global activate coverage
$ dart test --coverage=coverage
$ dart pub global run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info
```

To view the generated coverage report you can use [lcov](https://github.com/linux-test-project/lcov).

```sh
# Generate Coverage Report
$ genhtml coverage/lcov.info -o coverage/

# Open Coverage Report
$ open coverage/index.html
```

---
