#!/usr/bin/env bash
# scripts/fetch-artifacts.sh
#
# Fetch DBRepo release artifacts (OpenAPI spec, REST Markdown, Python Sphinx
# HTML) from a GitHub release on DBRepo-Project/dbrepo, falling back to the
# committed frozen copies when no version-matched release exists.
#
# Decisions implemented (see .planning/phases/04-release-artifact-ci-pipeline/
# 04-CONTEXT.md):
#   D-01 — Provisional + configurable asset names (env-overridable defaults).
#   D-02 — OpenAPI fetched asset name `openapi.yaml`, destination docs/.openapi/api.yaml.
#   D-03 — Tag normalization: monorepo tags `vX.Y.Z`, docs version is `X.Y`; resolve
#          the highest `v<docs_version>.*` patch release rather than calling
#          `gh release download <docs_version>`.
#   D-04 — No matching release → exit 0 with one deterministic log line.
#   D-09 — REST Markdown asset name `rest.md`, destination docs/api/rest.md.
#   D-15 — Use `gh` (with the auto-provided GITHUB_TOKEN) for all release access;
#          no curl on the primary fetch path (ART-01).
#   D-17 — Fetched content is ephemeral: this script only overlays files in the
#          working tree for the current build; it never stages or commits anything.
#   D-18 — Frozen copies are the committed baseline and are updated manually by a
#          maintainer; this script never mutates the git baseline.
#
# Threat model (T-04-01): RELEASE_REPO and RELEASE_TAG_OVERRIDE enter from
# workflow_dispatch inputs; both are validated against strict patterns before
# any `gh` invocation, and every variable expansion is quoted.

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults (D-01 — all asset names/destinations are env-overridable so the
# workflow is complete today and only a variable changes when the monorepo
# finalizes the release-asset naming contract).
# ----------------------------------------------------------------------------
: "${RELEASE_REPO:=DBRepo-Project/dbrepo}"
: "${DOC_VERSION:=1.13}"
: "${OPENAPI_ASSET:=openapi.yaml}"
: "${REST_ASSET:=rest.md}"
: "${PYTHON_ASSET:=python-sphinx.tar.gz}"
: "${RELEASE_TAG_OVERRIDE:=}"
: "${OPENAPI_DEST:=docs/.openapi/api.yaml}"
: "${REST_DEST:=docs/api/rest.md}"
: "${PYTHON_ARCHIVE:=/tmp/python-sphinx.tar.gz}"
: "${PYTHON_DEST_DIR:=docs/python}"

# ----------------------------------------------------------------------------
# validate_inputs — reject workflow_dispatch-controlled strings before any gh
# command runs (T-04-01 tampering mitigation).
# ----------------------------------------------------------------------------
validate_inputs() {
  # RELEASE_REPO must be OWNER/REPO with URL-safe characters only.
  if [[ ! "$RELEASE_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: RELEASE_REPO '$RELEASE_REPO' is not a valid OWNER/REPO string." >&2
    return 1
  fi

  # RELEASE_TAG_OVERRIDE, when provided, must match a release tag shape like
  # `v1.13.4` (D-19). Empty is allowed (means "auto-resolve").
  if [[ -n "$RELEASE_TAG_OVERRIDE" ]] \
     && [[ ! "$RELEASE_TAG_OVERRIDE" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: RELEASE_TAG_OVERRIDE '$RELEASE_TAG_OVERRIDE' is not a valid release tag (expected vX.Y.Z)." >&2
    return 1
  fi

  return 0
}

# ----------------------------------------------------------------------------
# resolve_tag — D-03 tag normalization.
#   Docs version is `X.Y` (e.g. 1.13); monorepo tags are `vX.Y.Z` (e.g. v1.13.4).
#   Resolve the highest `v<docs_version>.*` release tag, or emit the empty
#   string when no matching release exists.
#   The trailing dot in `startswith("v${DOC_VERSION}.")` prevents `v1.130.0`
#   from matching docs version `1.13`.
# ----------------------------------------------------------------------------
resolve_tag() {
  local version="$1" repo="$2"
  gh release list -R "$repo" --json tagName -L 100 \
    --jq "map(select(.tagName | startswith(\"v${version}.\"))) | sort | last | .tagName // \"\""
}

# ----------------------------------------------------------------------------
# main — orchestrate validation, tag resolution, and the (planned) per-asset
# fetch. This plan (04-01) only needs the no-release frozen-fallback path to
# exit 0 with the D-04 log line; per-asset gh release download wiring lands in
# a later plan. Fetched content is ephemeral per D-17/D-18 — nothing here
# stages or commits to git.
# ----------------------------------------------------------------------------
main() {
  validate_inputs

  # D-19: explicit tag override skips auto-resolution.
  local tag
  if [[ -n "$RELEASE_TAG_OVERRIDE" ]]; then
    tag="$RELEASE_TAG_OVERRIDE"
    echo "Using release tag override: $tag"
  else
    tag="$(resolve_tag "$DOC_VERSION" "$RELEASE_REPO")"
  fi

  if [[ -z "$tag" ]]; then
    # D-04 — one deterministic no-release fallback line naming the docs version
    # and repo. Exit 0 so the build proceeds with the frozen artifacts.
    echo "No release matching v${DOC_VERSION}.* found on ${RELEASE_REPO} — using frozen artifacts."
    exit 0
  fi

  echo "Resolved release tag: $tag"
  echo "DEBUG: OPENAPI_ASSET=$OPENAPI_ASSET -> $OPENAPI_DEST"
  echo "DEBUG: REST_ASSET=$REST_ASSET -> $REST_DEST"
  echo "DEBUG: PYTHON_ASSET=$PYTHON_ASSET -> $PYTHON_ARCHIVE (extract to $PYTHON_DEST_DIR)"
  echo "NOTE: per-asset fetch wiring (gh release download) is implemented in a later plan."
}

main "$@"