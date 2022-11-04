## changelog_cli

CLI to generate an opinionated changelog

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
$ changelog_cli generate
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
