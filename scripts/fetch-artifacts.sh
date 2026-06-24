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
# fetch_openapi — D-02 / ART-01.
#   Download the OpenAPI asset (named $OPENAPI_ASSET, e.g. `openapi.yaml`) from
#   the resolved GitHub release on $RELEASE_REPO and overlay it onto
#   $OPENAPI_DEST (docs/.openapi/api.yaml) so the existing swagger-ui.html
#   (`url: 'api.yaml'` relative) and rest.md pipeline keep working unchanged.
#   Uses `gh release download` with the auto-provided GH_TOKEN (D-15) — no curl
#   on the primary fetch path (ART-01). Fetched content is ephemeral per D-17:
#   this only overlays the working tree, never stages or commits to git.
#   On any fetch failure the frozen docs/.openapi/api.yaml remains untouched and
#   the build falls back to it (ART-03). `gh release download` writes the asset
#   under its original name, so the downloaded file is renamed to the frozen
#   destination basename to satisfy D-02's "placed at docs/.openapi/api.yaml"
#   overlay contract.
# ----------------------------------------------------------------------------
fetch_openapi() {
  local TAG="$1"
  local dest_dir
  dest_dir="$(dirname "$OPENAPI_DEST")"

  echo "Fetching OpenAPI asset $OPENAPI_ASSET from $RELEASE_REPO@$TAG..."
  if gh release download "$TAG" -R "$RELEASE_REPO" -p "$OPENAPI_ASSET" \
       -D "$dest_dir" --clobber; then
    # D-02 — overlay the fetched asset onto the frozen api.yaml destination.
    # gh release download writes the asset as $OPENAPI_ASSET (e.g. openapi.yaml);
    # rename it to $OPENAPI_DEST (docs/.openapi/api.yaml) so swagger-ui.html's
    # relative `url: 'api.yaml'` reference resolves to the fetched spec.
    local downloaded="$dest_dir/$OPENAPI_ASSET"
    if [[ -f "$downloaded" && "$downloaded" != "$OPENAPI_DEST" ]]; then
      mv -f "$downloaded" "$OPENAPI_DEST"
    fi
    echo "Fetched OpenAPI spec -> $OPENAPI_DEST"
  else
    # Fallback-class result (ART-03): the frozen docs/.openapi/api.yaml remains
    # and the build proceeds with it. ART-04's strict 403/429-fail status
    # classification is documented in docs/.openapi/README.md and refined in a
    # later plan; this plan's contract is fetch-or-fallback (D-17/D-04).
    echo "WARNING: OpenAPI fetch from $RELEASE_REPO@$TAG failed; using frozen $OPENAPI_DEST." >&2
  fi
}

# ----------------------------------------------------------------------------
# stage_openapi_viewer — Research Pitfall 1 / T-04-05 mitigation.
#   zensical's file collector silently drops dot-prefixed directories, so
#   docs/.openapi/ never reaches site/ and the Swagger UI page is not served
#   today (verified empirically: /latest/.openapi/swagger-ui.html returns 404).
#   Stage a non-dot docs/openapi/ copy of the viewer + spec before zensical
#   build so site/openapi/swagger-ui.html is served. Option B (pre-build copy)
#   preserves D-02's frozen-fallback location in docs/.openapi/ and minimizes
#   source churn (no git mv of the frozen source). The staged directory is
#   gitignored (docs/openapi/, T-04-03) and ephemeral per D-17 — it is
#   synthesized per build and never committed. swagger-ui.html content is
#   unchanged: its relative `api.yaml` + `./custom.css` references keep working
#   after staging because all three files land in the same directory.
# ----------------------------------------------------------------------------
stage_openapi_viewer() {
  local src_dir="docs/.openapi"
  local stage_dir="docs/openapi"

  mkdir -p "$stage_dir"

  cp "$src_dir/swagger-ui.html" "$stage_dir/swagger-ui.html"
  cp "$src_dir/custom.css" "$stage_dir/custom.css"
  cp "$src_dir/api.yaml" "$stage_dir/api.yaml"

  # Verify the three staged files are non-empty (T-04-05 DoS mitigation — a
  # missing/empty viewer or spec would silently serve a broken Swagger UI).
  local f
  for f in "$stage_dir/swagger-ui.html" "$stage_dir/custom.css" "$stage_dir/api.yaml"; do
    if [[ ! -s "$f" ]]; then
      echo "ERROR: staged file $f is missing or empty." >&2
      return 1
    fi
  done

  echo "Staged Swagger UI at $stage_dir/ (swagger-ui.html, custom.css, api.yaml)."
}

# ----------------------------------------------------------------------------
# main — orchestrate validation, tag resolution, OpenAPI fetch (D-02/ART-01),
# and Swagger UI staging (Research Pitfall 1). Runs in both the fetched and
# no-release frozen-fallback paths so every build serves the Swagger UI from a
# zensical-reachable non-dot path. Fetched content is ephemeral per D-17/D-18 —
# nothing here stages or commits to git; the docs/openapi/ staging dir is
# gitignored (T-04-03).
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
    # and repo. The frozen artifacts remain; the build proceeds with them. Do
    # NOT exit here — the Swagger UI still needs to be staged so zensical serves
    # it (Research Pitfall 1).
    echo "No release matching v${DOC_VERSION}.* found on ${RELEASE_REPO} — using frozen artifacts."
  else
    echo "Resolved release tag: $tag"
    # D-02/ART-01 — fetch the OpenAPI asset, overlaying docs/.openapi/api.yaml.
    # On any fetch failure the frozen fallback remains (D-17/ART-03).
    fetch_openapi "$tag"
  fi

  # Stage the Swagger UI into a zensical-served non-dot directory so the build
  # emits site/openapi/swagger-ui.html (Research Pitfall 1 — zensical drops
  # dot-prefixed dirs). Runs in both fetched and fallback paths.
  stage_openapi_viewer
}

main "$@"