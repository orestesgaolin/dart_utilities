## changelog_cli

CLI to generate an opinionated changelog.

<img src="https://raw.githubusercontent.com/orestesgaolin/dart_utilities/refs/heads/main/changelog_cli/example/screenshots/changelog_cli.png" alt="Example usage screenshot" width="600">

By default it just generates the changelog based on the whole git history. You can pass custom `--start` and `--end` parameters which are git refs to get a subset of changes between two commits or tags. That was my main goal with this CLI as it doesn't necessarily require semantic versioning.

**Features:**

- Generate changelogs from conventional commits
- Support for multiple output formats (simple, markdown, slack-markdown)
- Configuration files support (YAML/JSON) with command-line override
- Auto-detection of previous tags
- Filtering by commit types and date ranges
- Integration with JIRA for issue linking

---

## Installation

### Pub.dev

If the CLI application is available on [pub](https://pub.dev), activate globally via:

```sh
dart pub global activate changelog_cli
```

Or locally via:

```sh
dart pub global activate --source=path <path to this package>
```

### Homebrew

You can install the CLI via Homebrew:

```sh
brew tap orestesgaolin/tap
brew install changelog_cli
```

## Usage

Get usage information:

```sh
# Get general help
changelog_cli --help

# Get help for generate command
changelog_cli generate --help

# Get help for config command
changelog_cli config --help
```

### Managing Configuration

Create and manage configuration files:

```sh
# Get help for config command
changelog_cli config --help

# Create a YAML configuration file
changelog_cli config --init

# Create a JSON configuration file
changelog_cli config --init --format json

# Create a global configuration file
changelog_cli config --init --global
```

### Generating Changelog

Generate a changelog:

```sh
changelog_cli generate

# or more elaborate
changelog_cli generate --path ~/Projects/my-app --start 1.0.0 --end 1.1.0 --version 1.1.0 --limit 2000 --printer markdown --output CHANGELOG.md

# or with custom formatting
changelog_cli generate --path packages/something --start $CM_PREVIOUS_COMMIT --version "Version $BUILD_VERSION ($PROJECT_BUILD_NUMBER)" --printer slack-markdown --group-by date-asc --date-format-locale en_US --date-format yyyy-MM-dd

# for monorepos tagged with my_package-x.y.z pattern
changelog_cli generate --path lib/packages/my_package --auto true --auto-tag-glob-pattern "my_package*"
```

## Configuration Files

You can use configuration files to avoid repeating command-line arguments. The CLI supports both YAML and JSON configuration formats.

### Supported Configuration Files

The CLI looks for configuration files in the following order:

1. `.changelog_cli.yaml` (project-specific YAML)
2. `.changelogrc` (project-specific JSON)
3. `~/.changelog_cli.yaml` (global YAML)
4. `~/.changelogrc` (global JSON)

### Creating Configuration Files

Use the `config` command to create configuration files:

```sh
# Create a YAML configuration file in the current directory
changelog_cli config --init

# Create a JSON configuration file
changelog_cli config --init --format json

# Create a global configuration file
changelog_cli config --init --global
```

### Configuration Format

#### YAML Configuration (`.changelog_cli.yaml`)

```yaml
# Changelog CLI Configuration
changelog:
  # Git reference settings
  start: "" # Start git reference (e.g. commit SHA or tag)
  end: "" # End git reference (e.g. commit SHA or tag)
  path: "." # Path to the git repository or folder

  # Changelog content settings
  include: # List of conventional commit types to include
    - feat
    - fix
    - refactor
    - perf

  # Output settings
  printer: simple # Output format: simple, markdown, slack-markdown
  version: "" # Version to display in changelog header
  limit: 0 # Max length of changelog (0 = no limit)
  output: "" # Output file path (if empty, prints to console)

  # Grouping and formatting
  group_by: "" # Group entries: date-asc, date-desc, scope-asc, scope-desc
  date_format: "" # Date format (e.g. yyyy-MM-dd)
  date_format_locale: en_US

  # Auto-detection settings
  auto: false # Automatically detect previous tag
  auto_tag_glob_pattern: "" # Pattern for auto tag detection

  # Integration settings
  jira_url: "" # JIRA URL for issue linking
  jira_project_key: "" # JIRA project key (e.g. AB, VA) - if not set, matches any valid ticket
  output: "" # Output file path (if empty, prints to console)
```

#### JSON Configuration (`.changelogrc`)

```json
{
  "changelog": {
    "start": "",
    "end": "",
    "path": ".",
    "include": ["feat", "fix", "refactor", "perf"],
    "printer": "simple",
    "version": "",
    "limit": 0,
    "group_by": "",
    "date_format": "",
    "date_format_locale": "en_US",
    "auto": false,
    "auto_tag_glob_pattern": "",
    "jira_url": "",
    "jira_project_key": "",
    "output": ""
  }
}
```

### Precedence

Command-line arguments take precedence over configuration file settings. This allows you to:

1. Set common defaults in a configuration file
2. Override specific settings using command-line arguments when needed

For example, with this configuration file:

```yaml
changelog:
  printer: markdown
  include:
    - feat
    - fix
```

Running `changelog_cli generate --printer simple` will use the simple printer (overriding the config file) but still include only feat and fix commits from the configuration.

### Detection of Previous Tags

You can get the previous tag using git command and then pass it to `changelog_cli`:

```sh
git describe --tags --abbrev=0
changelog_cli generate --start changelog_cli-v0.0.2
```

### Printers

- `simple` - simple text output
- `markdown` - markdown output
- `slack-markdown` - markdown output with Slack-specific formatting

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
