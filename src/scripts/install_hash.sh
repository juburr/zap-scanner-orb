#!/bin/bash

# Convenience script, not used directly by the production orb, but
# for development purposes when adding SHA-512 checksums to the lookup
# table in install.sh.
#
# The downloaded tarball is first checked against a checksum published by the
# ZAP project, so that a new table entry is anchored to the upstream release
# rather than to whatever was downloaded. By default that checksum is read from
# the release notes on GitHub; pass -c to supply one from another official
# source (such as the zap-admin update feed), in the "SHA-256:<hex>" or
# "SHA1:<hex>" form used by scripts/upstream_checksums.txt. When both are
# available they must agree. "-c NONE" skips anchoring for releases that never
# had a published checksum.

set -e
set -o pipefail
set +o history

# Fetch CLI arguments
# Can also be set as environment variables.
while getopts :v:c: flag
do
    case "${flag}" in
        v) VERSION=${OPTARG};;
        c) UPSTREAM=${OPTARG};;
        *) echo "Invalid option: -${OPTARG}" >&2; exit 1;;
    esac
done

# Validate input arguments
if [[ -z "${VERSION}" ]]; then
  echo "Must specify a version number."
  echo "Usage: $0 -v 2.17.0 [-c SHA-256:<hex> | -c SHA1:<hex> | -c NONE]"
  echo "Alternatively: VERSION=2.17.0 $0"
  exit 1
fi
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: Invalid version '${VERSION}'." >&2
  exit 1
fi

TARBALL="ZAP_${VERSION}_Linux.tar.gz"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# Releases live in zaproxy/zaproxy until the ZAP project moves them to
# zaproxy/zap-archive.
RELEASES=(
  "zaproxy/zaproxy v${VERSION}"
  "zaproxy/zap-archive zap-v${VERSION}"
)

# Set GITHUB_TOKEN to avoid the unauthenticated API rate limit.
AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

# Prints the SHA-256 published for the tarball in a release's notes, if any.
# The API returns the notes as a single JSON string, so split its escaped
# newlines back into table rows before matching.
notes_sha256() {
  local repo=$1 tag=$2
  curl -fsSL --retry 3 "${AUTH_HEADER[@]}" "https://api.github.com/repos/${repo}/releases/tags/${tag}" 2> /dev/null \
    | sed 's/\\n/\n/g' \
    | grep -F "[${TARBALL}]" \
    | grep -oE '[0-9a-f]{64}' \
    | head -n 1 || true
}

NOTES_SHA256=""
if [[ "${UPSTREAM:-}" != "NONE" ]] && [[ "${SKIP_RELEASE_NOTES:-}" != "true" ]]; then
  for release in "${RELEASES[@]}"; do
    read -r repo tag <<< "${release}"
    NOTES_SHA256=$(notes_sha256 "${repo}" "${tag}")
    [[ -n "${NOTES_SHA256}" ]] && break
  done
fi

# Collect every checksum the download must match.
declare -a CHECKS=()
if [[ -n "${NOTES_SHA256}" ]]; then
  CHECKS+=("SHA-256:${NOTES_SHA256}")
fi
if [[ -n "${UPSTREAM:-}" ]] && [[ "${UPSTREAM}" != "NONE" ]]; then
  if [[ ! "${UPSTREAM}" =~ ^(SHA-256:[0-9a-f]{64}|SHA1:[0-9a-f]{40})$ ]]; then
    echo "ERROR: -c must be SHA-256:<hex>, SHA1:<hex>, or NONE." >&2
    exit 1
  fi
  CHECKS+=("${UPSTREAM}")
fi
if [[ "${#CHECKS[@]}" -eq 0 ]]; then
  if [[ "${UPSTREAM:-}" == "NONE" ]]; then
    echo "WARN: No upstream checksum for ${TARBALL}; the SHA-512 is not anchored to a published value." >&2
  else
    echo "ERROR: No published checksum found for ${TARBALL}. Supply one with -c." >&2
    exit 1
  fi
fi

# Download the specified version. Suppress output for readability; this is a
# dev script, so simply re-enable output if you need to debug anything.
DOWNLOADED="false"
for release in "${RELEASES[@]}"; do
  read -r repo tag <<< "${release}"
  if curl -fsSL --retry 3 "https://github.com/${repo}/releases/download/${tag}/${TARBALL}" -o "${WORK_DIR}/${TARBALL}" 2> /dev/null; then
    DOWNLOADED="true"
    break
  fi
done
if [[ "${DOWNLOADED}" != "true" ]]; then
  echo "ERROR: ${TARBALL} is not available from ${RELEASES[*]%% *}." >&2
  exit 1
fi

for check in "${CHECKS[@]}"; do
  expected=${check#*:}
  case "${check%%:*}" in
    SHA-256) actual=$(sha256sum "${WORK_DIR}/${TARBALL}" | awk '{ print $1 }') ;;
    SHA1) actual=$(sha1sum "${WORK_DIR}/${TARBALL}" | awk '{ print $1 }') ;;
  esac
  if [[ "${actual}" != "${expected}" ]]; then
    echo "ERROR: ${check%%:*} mismatch for ${TARBALL}." >&2
    echo "  Published: ${expected}" >&2
    echo "  Actual:    ${actual}" >&2
    exit 1
  fi
done

CHECKSUM=$(sha512sum "${WORK_DIR}/${TARBALL}" | awk '{ print $1 }')
echo "[\"${VERSION}\"]=\"${CHECKSUM}\""
