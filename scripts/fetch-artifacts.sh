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
# fetch_rest — D-09 / D-10.
#   Download the REST Markdown asset (named $REST_ASSET, e.g. `rest.md`) from
#   the resolved GitHub release on $RELEASE_REPO and overlay it onto
#   $REST_DEST (docs/api/rest.md). This fetch is INDEPENDENT of the OpenAPI
#   and Python fetches per D-10: a partial release that ships only some assets
#   degrades per-asset. Uses `gh release download` with the auto-provided
#   GH_TOKEN (D-15). The asset name equals the destination basename, so no
#   rename is needed. On any fetch failure the frozen docs/api/rest.md remains
#   untouched and the build falls back to it (ART-03). Fetched content is
#   ephemeral per D-17.
# ----------------------------------------------------------------------------
fetch_rest() {
  local TAG="$1"
  local dest_dir
  dest_dir="$(dirname "$REST_DEST")"

  echo "Fetching REST asset $REST_ASSET from $RELEASE_REPO@$TAG..."
  if gh release download "$TAG" -R "$RELEASE_REPO" -p "$REST_ASSET" \
       -D "$dest_dir" --clobber; then
    echo "Fetched REST Markdown -> $REST_DEST"
  else
    # Fallback-class result (ART-03): the frozen docs/api/rest.md remains and
    # the build proceeds with it. Independent of OpenAPI/Python outcome (D-10).
    echo "WARNING: REST fetch from $RELEASE_REPO@$TAG failed; using frozen $REST_DEST." >&2
  fi
}

# ----------------------------------------------------------------------------
# fetch_python — D-05 / D-08.
#   Download the Python Sphinx HTML archive (named $PYTHON_ASSET, e.g.
#   `python-sphinx.tar.gz`) from the resolved GitHub release on $RELEASE_REPO
#   into $PYTHON_ARCHIVE (/tmp/python-sphinx.tar.gz). Python uses the same
#   ART-04 error flow as OpenAPI per D-08 (404→silent fallback, missing→warn,
#   fetch failure→use landing page without the Sphinx link rendered). On any
#   fetch failure the archive is not produced and the landing page keeps its
#   committed fallback block (update_python_landing respects the absence of
#   docs/python/.fetched). Fetched content is ephemeral per D-17.
# ----------------------------------------------------------------------------
fetch_python() {
  local TAG="$1"
  local dest_dir
  dest_dir="$(dirname "$PYTHON_ARCHIVE")"

  echo "Fetching Python Sphinx asset $PYTHON_ASSET from $RELEASE_REPO@$TAG..."
  if gh release download "$TAG" -R "$RELEASE_REPO" -p "$PYTHON_ASSET" \
       -D "$dest_dir" --clobber; then
    echo "Fetched Python Sphinx archive -> $PYTHON_ARCHIVE"
  else
    # Fallback-class result (ART-03): the archive is not produced; the landing
    # page keeps its committed fallback block (D-07). Independent of OpenAPI /
    # REST outcome (D-10).
    echo "WARNING: Python Sphinx fetch from $RELEASE_REPO@$TAG failed; landing page keeps the fallback block." >&2
  fi
}

# ----------------------------------------------------------------------------
# extract_python_sphinx — D-05 / D-08 / T-04-07.
#   Extract the fetched Sphinx HTML archive into $PYTHON_DEST_DIR (docs/python)
#   and write the docs/python/.fetched sentinel ONLY after successful
#   extraction and index.html presence check (T-04-07 tampering mitigation).
#   The archive may contain the Sphinx HTML at the root, under a single
#   top-level `html/` directory, or under a single top-level `build/html/`
#   directory (covers the monorepo's build-site.sh output shapes); the function
#   normalizes all three into docs/python/ with index.html at the root. Any
#   stale docs/python/ is removed before extraction so a failed prior run does
#   not masquerade as a fresh fetch. On any failure docs/python/ is cleaned up
#   and the .fetched sentinel is NOT written, so update_python_landing keeps
#   the committed fallback block (D-09/D-17). docs/python/ is gitignored
#   (per-build, ephemeral).
# ----------------------------------------------------------------------------
extract_python_sphinx() {
  # Nothing to extract if the archive fetch did not produce a file.
  if [[ ! -s "$PYTHON_ARCHIVE" ]]; then
    return 0
  fi

  # Remove any stale docs/python/ from a prior run so a failed extraction
  # cannot leave a stale .fetched sentinel masquerading as success (D-07).
  rm -rf "$PYTHON_DEST_DIR"
  mkdir -p "$PYTHON_DEST_DIR"

  # Work in a private scratch dir so the archive's own top-level layout can be
  # inspected and normalized into docs/python/ with index.html at the root.
  local scratch
  scratch="$(mktemp -d)"
  if ! tar -xf "$PYTHON_ARCHIVE" -C "$scratch"; then
    echo "WARNING: Python Sphinx archive $PYTHON_ARCHIVE failed to extract; landing page keeps the fallback block." >&2
    rm -rf "$scratch" "$PYTHON_DEST_DIR"
    return 0
  fi

  # Determine the Sphinx HTML root inside the scratch tree. Supports three
  # archive shapes observed in monorepo build outputs:
  #   (a) files at root (index.html, _static/, _sources/, ...)
  #   (b) single top-level html/ directory containing the Sphinx site
  #   (c) single top-level build/html/ directory containing the Sphinx site
  local html_root="$scratch"
  if [[ -f "$scratch/index.html" ]]; then
    html_root="$scratch"
  elif [[ -d "$scratch/html" && -f "$scratch/html/index.html" ]]; then
    html_root="$scratch/html"
  elif [[ -d "$scratch/build/html" && -f "$scratch/build/html/index.html" ]]; then
    html_root="$scratch/build/html"
  else
    echo "WARNING: Python Sphinx archive $PYTHON_ARCHIVE has no index.html at root, html/, or build/html/; landing page keeps the fallback block." >&2
    rm -rf "$scratch" "$PYTHON_DEST_DIR"
    return 0
  fi

  # Overlay the normalized Sphinx site into docs/python/. The trailing slash on
  # $html_root/ ensures cp -r copies the directory's contents, not the dir
  # itself, so docs/python/index.html (not docs/python/<scratch>/index.html).
  cp -r "$html_root/" "$PYTHON_DEST_DIR/"

  # T-04-07 — do not write the .fetched sentinel unless the extracted site has
  # a usable entrypoint. A missing index.html means the archive was not a valid
  # Sphinx site; the landing page keeps its committed fallback block (D-07).
  if [[ ! -f "$PYTHON_DEST_DIR/index.html" ]]; then
    echo "WARNING: extracted Python Sphinx site has no index.html; landing page keeps the fallback block." >&2
    rm -rf "$scratch" "$PYTHON_DEST_DIR"
    return 0
  fi

  touch "$PYTHON_DEST_DIR/.fetched"
  rm -rf "$scratch"
  echo "Extracted Python Sphinx HTML -> $PYTHON_DEST_DIR (sentinel .fetched written)."
}

# ----------------------------------------------------------------------------
# update_python_landing — D-06 / D-07 / D-17.
#   Conditionally rewrite the Sphinx section of docs/api/python.md in the CI
#   working tree so the reader sees the Open Sphinx API reference CTA when the
#   Sphinx HTML was fetched and staged, and the honest fallback notice
#   otherwise. The committed baseline in git ALWAYS retains the fallback
#   blockquote (D-17 — fetched content is ephemeral; this only overlays the
#   working tree for the current build). The block swap targets the committed
#   "Sphinx UI not yet available" blockquote and replaces the whole Sphinx
#   section with the UI-SPEC C1 fetched form, leaving Version matching and
#   Installation untouched.
# ----------------------------------------------------------------------------
update_python_landing() {
  # No fetch happened (no docs/python/ at all, or extraction did not write the
  # sentinel) -> the committed fallback block stays (D-07/D-17).
  if [[ ! -f "$PYTHON_DEST_DIR/.fetched" ]]; then
    return 0
  fi

  local landing="docs/api/python.md"
  if [[ ! -f "$landing" ]]; then
    echo "WARNING: $landing not found; cannot install Sphinx CTA." >&2
    return 0
  fi

  # Build the replacement with the fetched-form Sphinx section (UI-SPEC C1).
  # The awk-based swap replaces the "## Sphinx API reference" H2 heading and
  # the blockquote that immediately follows it (the committed fallback block)
  # with the fetched-form CTA block, then prints the rest of the file
  # (Version matching and Installation sections) verbatim.
  local replacement
  replacement="## Sphinx API reference

The full Python API reference is rendered by Sphinx and published as a release artifact from
the [DBRepo monorepo](https://github.com/DBRepo-Project/dbrepo).

[:octicons-arrow-right-24: Open Sphinx API reference](/python/)

The Sphinx pages open in a sibling path under this version; use your browser's back button to
return to this page."

  # In-place swap: from the "## Sphinx API reference" line through the end of
  # the blockquote (the last line beginning with `> `), print the replacement,
  # then resume printing from the next H2 (## ) that follows. awk is used
  # because the blockquote length is not fixed across the committed and
  # script-produced forms.
  local tmp
  tmp="$(mktemp)"
  awk -v replacement="$replacement" '
    /^## Sphinx API reference$/ { in_block = 1; print replacement; next }
    in_block && /^> / { next }
    in_block && /^## / { in_block = 0; print; next }
    in_block && NF == 0 { next }
    in_block && !/^> / && !/^## / { in_block = 0; print; next }
    { print }
  ' "$landing" > "$tmp"

  mv -f "$tmp" "$landing"
  echo "Updated $landing with the Open Sphinx API reference CTA (fetched form)."
}

# ----------------------------------------------------------------------------
# main — orchestrate validation, tag resolution, per-asset fetch (D-02 D-09
# D-05; ART-01), Python Sphinx extraction (D-05/D-08), Swagger UI staging
# (Research Pitfall 1), and the conditional Python landing-page block swap
# (D-06/D-17). Runs in both the fetched and no-release frozen-fallback paths
# so every build serves the Swagger UI from a zensical-reachable non-dot path
# and the Python landing page reflects whether Sphinx HTML was fetched.
# Fetched content is ephemeral per D-17/D-18 — nothing here stages or commits
# to git; the docs/openapi/ and docs/python/ staging dirs are gitignored.
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
    # it (Research Pitfall 1), and update_python_landing will keep the
    # committed Python fallback block because no .fetched sentinel exists.
    echo "No release matching v${DOC_VERSION}.* found on ${RELEASE_REPO} — using frozen artifacts."
  else
    echo "Resolved release tag: $tag"
    # D-02 / ART-01 — fetch OpenAPI; frozen fallback remains on any failure.
    fetch_openapi "$tag"
    # D-09 / D-10 — fetch REST Markdown INDEPENDENTLY of OpenAPI/Python.
    fetch_rest "$tag"
    # D-05 / D-08 — fetch Python Sphinx archive; on failure the landing page
    # keeps the fallback block (D-07).
    fetch_python "$tag"
    # D-05 / D-08 / T-04-07 — extract into docs/python/ and write .fetched only
    # after a valid index.html is present.
    extract_python_sphinx
  fi

  # Stage the Swagger UI into a zensical-served non-dot directory so the build
  # emits site/openapi/swagger-ui.html (Research Pitfall 1 — zensical drops
  # dot-prefixed dirs). Runs in both fetched and fallback paths.
  stage_openapi_viewer

  # D-06 / D-17 — swap the Python landing-page Sphinx section to the fetched
  # CTA only when docs/python/.fetched exists; otherwise the committed
  # fallback block stays in place (D-07).
  update_python_landing
}

main "$@"