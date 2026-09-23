<div align="center">
  <img align="center" width="320" src="assets/logos/zap-scanner-orb-512px.png" alt="ZAP Scanner Orb">
  <h1>CircleCI ZAP Scanner Orb</h1>
  <i>An orb for simplifying OWASP ZAP installation and performing DAST scans within CircleCI.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/zap-scanner-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/zap-scanner-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/zap-scanner-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/zap-scanner-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/zap-scanner-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This is an unofficial [OWASP ZAP](https://www.zaproxy.org/) orb used for
installing ZAP in your CircleCI pipeline and performing dynamic application
security testing (DAST) of web applications and APIs. Contributions are
welcome!

## Features
### **Secure By Design**
- **Least Privilege**: Installs to user-owned directories by default, with no `sudo` usage anywhere in this orb.
- **Integrity**: Checksum validation of all downloaded release archives using SHA-512, anchored to the SHA-256 checksums ZAP publishes with each release. Cached archives are re-verified on every restore.
- **Provenance**: Installs directly from ZAP's official [releases page](https://github.com/zaproxy/zaproxy/releases/) on GitHub. No third-party websites, domains, or proxies are used.
- **Confidentiality**: All secrets and environment variables are handled in accordance with CircleCI's [security recommendations](https://circleci.com/docs/security-recommendations/) and [best practices](https://circleci.com/docs/orbs-best-practices/).
- **Privacy**: No usage data of any kind is collected or shipped back to the orb developer. Scans run ZAP with `-silent`, so ZAP itself makes no unsolicited requests, such as update checks or telemetry, to its own services.

Info for security teams:
- Required external access to allow, if running a locked down, self-hosted CircleCI pipeline on-prem:
  - `github.com` and `objects.githubusercontent.com`: For download and installation of ZAP.
  - Scans only contact the target, plus the `api_definition` URL if one is given. Every add-on the scans use is bundled with the ZAP release, so nothing is downloaded at scan time.

## Requirements

- A Linux executor (Docker or machine), on amd64 or arm64.
- A Java runtime compatible with the ZAP version (see below). ZAP's Linux
  release does not bundle one; the `cimg/openjdk` images work out of the box.
  From ZAP 2.17.0 onward, `JAVA_HOME` is honored when set. Earlier releases'
  launchers ignore `JAVA_HOME` and require `java` on the `PATH`, and the orb
  checks whichever Java the release will actually use.
- `bash`, `tar`, `gzip`, `sha512sum`, and either `curl` or `wget`.

The `install` command checks for Java before downloading anything, then checks
the version against the minimum declared by the ZAP release being installed.

### Supported ZAP versions

Every ZAP release still hosted by the ZAP project can be installed with
`verify_checksums: strict`:

| ZAP version | Java | Executor example |
|---|---|---|
| 2.16.0 – 2.17.0 | 17 or newer | `cimg/openjdk:21.0` |
| 2.12.0 – 2.15.0 | 11 or newer | `cimg/openjdk:21.0` |
| 2.7.0 – 2.11.1 | 8 or newer | `cimg/openjdk:21.0` |
| 2.4.0, 2.4.2, 2.4.3, 2.5.0 | 7 or 8 only | `cimg/openjdk:8.0` |

The `scan` command requires ZAP 2.12.0 or newer.

ZAP 2.0.0 through 2.3.1, 2.4.1, and 2.6.0 are no longer hosted anywhere by the
ZAP project and cannot be installed. Releases older than the most recent one
are downloaded from [zaproxy/zap-archive](https://github.com/zaproxy/zap-archive)
once the ZAP project moves them there. The ZAP project only supports its latest
release, and older releases may contain known vulnerabilities, so the command
warns when installing anything else.

## Example Usage

```yaml
version: 2.1

orbs:
  zap: juburr/zap-scanner-orb@0

parameters:
  zap_version:
    type: string
    default: "2.17.0"

jobs:
  dast:
    docker:
      - image: cimg/openjdk:21.0
      # The application under test, reachable at localhost.
      - image: bkimminich/juice-shop:latest
    steps:
      - zap/install:
          verify_checksums: strict
          version: << pipeline.parameters.zap_version >>
      - zap/scan:
          target: http://localhost:3000
          fail_on: medium

workflows:
  security:
    jobs:
      - dast
```

The scan waits for the application to respond, spiders it, and fails the job
if any passive scan alert is medium risk or higher. The HTML, JSON, and
Markdown reports are stored as artifacts under `zap-reports/` whether the scan
passes or fails.

## Commands

### `install`

Downloads the `ZAP_<version>_Linux.tar.gz` release archive, verifies it,
extracts it to `install_path`, and symlinks `zap.sh` into `bin_path`. If
`bin_path` is not already on the `PATH`, it is added for subsequent steps.
`ZAP_INSTALL_PATH` and `ZAP_VERSION` are also exported to subsequent steps.

| Parameter | Default | Description |
|---|---|---|
| `caching` | `true` | Cache the release archive, keyed by version. |
| `install_path` | `$HOME/zap` | Absolute directory to extract ZAP into. Must not exist or be empty. |
| `bin_path` | `$HOME/bin` | Absolute directory for the `zap.sh` symlink. |
| `verify_checksums` | `known_versions` | `strict`, `known_versions`, or `false`. |
| `version` | `2.17.0` | ZAP version to install. |

Environment variables such as `$HOME` are expanded in `install_path` and
`bin_path`.

**Checksum verification.** Every supported version has a pinned SHA-512
checksum. Each one was derived from a download that matched the checksum the
ZAP project published for that release (SHA-256 for 2.8.0 and newer, SHA-1 for
older releases), as recorded in
[`src/scripts/upstream_checksums.txt`](src/scripts/upstream_checksums.txt).
The one exception is 2.8.1, a Kali-only bug fix release for which the ZAP
project never published a checksum; it is pinned to the archive the ZAP project
serves on GitHub. With `known_versions`, releases newer than this orb's
checksum table install with a warning. With `strict` (recommended), they fail
before anything is downloaded.

**Caching.** The archive is cached under `zap-scanner-orb-v1-<version>` and
re-verified after every restore. If a cached archive no longer matches its
checksum, it is discarded and downloaded again rather than failing the build.

**Re-running.** Invoking `install` again with the same `install_path` and
`version` is a no-op, so it is safe to call from multiple reusable commands in
one job. Installing into a non-empty directory that this orb did not create, or
over a different version, fails without touching the existing files.

**Atomicity.** ZAP is extracted into a staging directory beside `install_path`
and only moved into place once it has been verified, so a failed install never
leaves a partially populated directory.

### `scan`

Runs a headless scan with ZAP's
[Automation Framework](https://www.zaproxy.org/docs/automate/automation-framework/)
and stores the reports as artifacts. Run `install` earlier in the same job.

| `scan_type` | What it does | Attacks the target |
|---|---|---|
| `baseline` (default) | Spiders `target`, then reports passive scan alerts. | No |
| `full` | As `baseline`, then runs an active scan. | Yes |
| `api` | Imports `api_definition` (OpenAPI), then runs an active scan. | Yes |

Only run `full` and `api` scans against applications you are authorized to
test, ideally one started in the same job as a service container or background
step.

| Parameter | Default | Description |
|---|---|---|
| `target` | | URL to scan. Required unless `plan` is set. |
| `scan_type` | `baseline` | `baseline`, `full`, or `api`. |
| `api_definition` | | Path or URL of an OpenAPI definition, for `api` scans. |
| `plan` | | Custom Automation Framework plan to run instead. |
| `fail_on` | `medium` | Fail on alerts at or above `high`, `medium`, `low`, or `info`, or `never`. |
| `spider_minutes` | `1` | Spider time limit for `baseline` and `full` scans, or `0` for none. |
| `active_scan_minutes` | `10` | Active scan time limit for `full` and `api` scans, or `0` for none. |
| `wait_for_target` | `60` | Seconds to wait for `target` to respond before scanning, or `0` to skip. |
| `max_memory` | `1g` | Maximum Java heap size for ZAP. |
| `report_dir` | `/tmp/zap-reports` | Absolute directory for the reports, plan, and ZAP log. |
| `store_artifacts` | `true` | Store `report_dir` as artifacts under `zap-reports/`. |
| `extra_options` | | Additional `zap.sh` options, split on whitespace. |
| `no_output_timeout` | `30m` | How long the scan may run silently before CircleCI stops it. |

Environment variables are expanded in `target`, `api_definition`, `plan`, and
`extra_options`. `report_dir` is passed to `store_artifacts` as is, so it must
be a literal path.

**Results.** `report_dir` receives `report.html`, `report.json`, and
`report.md`, along with the generated `plan.yaml` and ZAP's `zap.log`. These
files are replaced if an earlier scan wrote them, but other files in the
directory are left alone. Give each scan in a job its own `report_dir` to
keep all of their reports. The step prints the number of alerts at each risk level, and fails if any alert is
at or above `fail_on`. It also fails if ZAP reports a plan error, such as the
target refusing connections. Alerts are counted by type, so one missing header
on 50 pages is one alert.

**Custom plans.** Set `plan` to run your own plan, for example one with
authentication configured, exported from the ZAP desktop app. The plan can
reference `${ZAP_TARGET}` and `${ZAP_REPORT_DIR}`, which are set from `target`
and `report_dir`. `fail_on`, `scan_type`, and the time limits don't apply to
custom plans, so end the plan with an `exitStatus` job (ZAP 2.16.0 or newer)
to fail on alerts. The step fails when ZAP exits with a plan error (exit code
1), and passes with a warning on plan warnings (exit code 2).

**Isolation.** Each scan uses a fresh, temporary ZAP home directory rather
than `~/.ZAP`, and an explicit heap size. Without one, the JVM sizes its heap
from the host's memory rather than the container's limit, which can get ZAP
killed on smaller resource classes.

## Troubleshooting

| Error | Resolution |
|---|---|
| `no java executable was found` | Use a `cimg/openjdk` image, or set `JAVA_HOME` in an earlier step (ZAP 2.17.0+). |
| `ignores JAVA_HOME, so java must be on the PATH` | Add `$JAVA_HOME/bin` to the `PATH` for ZAP releases before 2.17.0. |
| `requires Java 17 or newer, but found Java ...` | Upgrade the executor's Java, or point `JAVA_HOME` at a newer runtime. |
| `only runs on Java 7 or 8` | Use `cimg/openjdk:8.0` for ZAP 2.5.0 and older, or pick a newer ZAP. |
| `Unable to download ZAP ...` | The version was never released, or is no longer hosted by the ZAP project. |
| `No checksum available for version ... and strict mode is enabled` | Upgrade the orb, or temporarily use `verify_checksums: known_versions`. |
| `... already exists and is not empty` | Choose a different `install_path`, or remove the directory first. |
| `zap.sh was not found on the PATH` | Run `install` earlier in the same job as `scan`. |
| `... did not respond within ...s` | Check that the application started and listens on the `target` host and port, or raise `wait_for_target`. |
| `alert type(s) at or above fail_on` | Review `report.html` in the job's artifacts, then fix the findings or raise `fail_on`. |
| `ZAP scan failed (exit code 1)` | Look for "Automation plan failures" in the output. The target may be unreachable. |
| ZAP is killed, or runs out of memory | Raise `max_memory`, or use a larger `resource_class`. |
| `Too long with no output` | Raise `no_output_timeout`, or lower `active_scan_minutes`. |

## Development

### Adding a new ZAP version

```bash
bash src/scripts/install_hash.sh -v 2.18.0
```

This downloads the release archive, checks it against the SHA-256 checksum ZAP
publishes in the GitHub release notes, and prints the SHA-512 entry to add to
the table in `src/scripts/install.sh`. Set `GITHUB_TOKEN` to avoid GitHub API
rate limits. Pass `-c SHA-256:<hex>` to also check against a checksum from
another official source, such as the `<linux>` entry in
[ZapVersions.xml](https://raw.githubusercontent.com/zaproxy/zap-admin/master/ZapVersions.xml).

Then:

1. Add the published checksum to `src/scripts/upstream_checksums.txt`.
2. Add the version to the test matrix for the oldest Java it supports in
   `.circleci/test-deploy.yml`. Don't rely on the "minimum of Java" line in
   `zap.sh` alone: ZAP 2.16.0's launcher declares Java 11 but its classes
   require Java 17. Confirm with the class file version of
   `org/zaproxy/zap/ZAP.class` in `zap-<version>.jar` (major version minus 44),
   and add a `min_java_overrides` entry in `install.sh` if they disagree.
3. When bumping the default `version`, move the previous default into the
   appropriate matrix.

CI fails if any of these are missing or disagree.

### Testing

Every push runs the following in `.circleci/test-deploy.yml`, and publishing
requires all of them to pass:

- The `install` command on `cimg/openjdk` 17, 21, and 25, on both amd64 and
  arm64, plus every older pinned ZAP version on the oldest Java it supports.
- A headless ZAP daemon started from the install and queried over its API.
- Machine executors on amd64 and arm64 with Java reachable only via `JAVA_HOME`.
- A stock `eclipse-temurin` image running as root, without `/home/circleci`.
- Paths containing spaces and environment variables, with caching disabled.
- Repeated invocation in one job, and a cache save/restore round trip.
- `.circleci/scripts/install_script_tests.sh`, which runs the install script
  directly against malformed input, missing tools, old or unparseable Java,
  cache corruption, and other failure paths.
- A check that re-derives every pinned checksum from the values recorded in
  `upstream_checksums.txt`, and that every pinned version is tested.
- The `scan` command running baseline, full, api, and custom plan scans of an
  nginx service container, plus a baseline scan with ZAP 2.12.0 on Java 11.
- `.circleci/scripts/scan_script_tests.sh`, which runs the scan script against
  a fake `zap.sh` to cover validation, plan generation, and result handling,
  then runs real scans of each type.

The test scripts can also be run locally with Java 17+ on the `PATH`:

```bash
bash .circleci/scripts/install_script_tests.sh
# Fake zap.sh tests only. For real scans, also put zap.sh on the PATH and set
# SCAN_TARGET to a running web server.
bash .circleci/scripts/scan_script_tests.sh
```
