# Deploying a new release

The chart below illustrates the release process for a new package version. The main entry point is the `release.yaml` workflow, which can be triggered manually from the Actions tab. It will guide you through selecting the package to release and then automate the rest of the process, including changelog generation, tagging, creating a GitHub release, building binaries, and updating the Homebrew tap.

```mermaid
  flowchart TD
      Dev([Maintainer]) -->|"manually runs Create Package Release<br/>(workflow_dispatch, picks package)"| REL

      subgraph DU["repo: orestesgaolin/dart_utilities"]
          direction TB

          subgraph CI["Per-package CI — on push to main"]
              CIa["changelog_cli · slack_cli · disk_analyzer_cli<br/>git_chain · git_branches<br/>analyze · test · build"]
          end

          subgraph RELJOB["release.yaml"]
              direction TB
              REL["job: release"]
              REL --> R1["Resolve package config<br/>build matrix · printer · mode"]
              R1 --> R2["Read version: pubspec + version.dart<br/>verify they match"]
              R2 --> R3{"Tag pkg-vX.Y.Z<br/>already exists?"}
              R3 -->|yes| FAIL["❌ fail the run"]
              R3 -->|no| R4{"Version already<br/>in CHANGELOG.md?"}
              R4 -->|yes| R5a["extract existing section as<br/>release notes — skip generation"]
              R4 -->|no| R5b["generate changelog,<br/>prepend to CHANGELOG.md"]
              R5a --> R6["Commit CHANGELOG + push main<br/>(RELEASE_PAT)"]
              R5b --> R6
              R6 --> R7["Create + push tag pkg-vX.Y.Z<br/>(RELEASE_PAT)"]
              R7 --> R8["Create DRAFT GitHub release<br/>with notes"]

              R8 --> BUILD["job: build_assets<br/>build per-OS binaries<br/>(exe or bundle, no macos-13)"]
              BUILD --> UPL["job: upload_artifacts<br/>attach assets + publish release<br/>(draft:false)"]
              UPL --> HB["job: update_homebrew<br/>gh workflow run update-pkg.yml"]
          end

          subgraph PUBJOB["publish.yaml — on tag push / workflow_dispatch"]
              PUB["job: publish<br/>verify tag==pubspec<br/>dart pub publish --force"]
          end

          REL -.->|new package commit| CI
      end

      R7 ==>|"tag push triggers it<br/>(works only because PAT, not GITHUB_TOKEN)"| PUB
      PUB ==>|"OIDC — no stored secret"| PUBDEV[("pub.dev<br/>git_chain · disk_analyzer_cli · git_branches")]

      HB ==>|"workflow_dispatch<br/>(RELEASE_PAT, actions:write)"| TAP

      subgraph TAPREPO["repo: orestesgaolin/homebrew-tap"]
          direction TB
          TAP["update-pkg.yml"]
          TAP --> T1["fetch latest release tag<br/>from dart_utilities API"]
          T1 --> T2["download source tarball<br/>+ release binaries"]
          T2 --> T3["compute sha256 checksums"]
          T3 --> T4["rewrite formula .rb<br/>(arm64 mac + linux only)"]
          T4 --> T5["commit + tag in tap"]
      end

      UPL -.->|"published release + assets<br/>read by the tap"| T2


```
