Resolving dependencies...
Downloading packages...
No dependencies would change in `/home/runner/work/dart_utilities/dart_utilities/changelog_cli`.

Completion files installed. To enable completion, run the following command in your shell:
source /home/runner/.bash_profile

## 0.6.1

**Bug Fixes**

- update image URL in README to use the correct reference
- update version to 0.6.1 to get rid of unnecessary update prompt - no functional changes (fixes #16)



Update available! 0.6.1 → 0.6.0
Run changelog_cli update to update

## 0.6.0

**Features**

- add configuration management for changelog generation with YAML and JSON support

## 0.5.1

**Bug Fixes**

- **changelog_cli**: use single asterix for bold text in slack-markdown printer

## 0.5.0

**Features**

- **changelog_cli**: add support for linking Jira tickets when jira-url option provided

## 0.4.0

**Features**

- **changelog_cli**: add support for glob patterns when detecting the previous tag automatically

## 0.3.0

**Features**

- **changelog_cli**: enhance generate command with new options for grouping and formatting changelog entries (`--group-by`, `--date-format`, `--date-format-locale`) (2024-10-15)

**Refactor**

- **changelog_cli**: use --path option to limit the commits to the provided directory (2024-10-15)

## 0.2.0

**Features**

- add slack-markdown printer

## 0.1.0

**Chores**

- update major dependencies (conventional_commit, file, pub_updater)
- **deps**: bump pub_updater from 0.2.4 to 0.3.0 in /changelog_cli

**Refactor**

- update to the latest very_good_cli template, enable completion support

## 0.0.6+1

**Refactor**

- add basic usage reporting

## 0.0.6

**Features**

- add markdown printer and expose `--printer` option

## 0.0.5

**Features**

- **simple_printer**: include scope of the conventional commit

## 0.0.4

**Features**

- add auto flag that generates the changelog from the latest tag accessible via git describe

## 0.0.3+5

**Refactor**

- use shorter name for CI type

## 0.0.3+4

**Documentation**

- update screenshot

## 0.0.3+3

- no changes

## 0.0.3+2

**Bug Fixes**

- handle bad git revision in generate command

## 0.0.3+1

**Bug Fixes**

- don't include version in header if not provided

## 0.0.3

**Features**

- let manually specify the version

## 0.0.2+5

**Refactor**

- improve simple printer
- extract getting git dir from arg
- use human readable names for sections

## 0.0.2+4

**Refactor**

- use human readable names for sections

## 0.0.2

**Features**

- add limit option
- add simple printer
- add initial implementation of the changelog_cli
