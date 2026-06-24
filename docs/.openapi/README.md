---
author: Martin Weise
---

# OpenAPI artifacts

This directory holds the docs-consumed OpenAPI inputs for the DBRepo documentation
site. Two kinds of files live here:

- **`api.yaml`** — the OpenAPI 3.0 spec for the REST API. It is the frozen fallback
  committed to this repo (ART-03) and the destination the fetch step overwrites when a
  matching release exists. The frozen copy stays committed as the baseline so the site
  keeps building before the first GitHub release ships.
- **`swagger-ui.html`** + **`custom.css`** — the static Swagger UI viewer for
  `api.yaml`. Swagger UI Dist 5.18.2 is loaded client-side from the `unpkg.com` CDN at
  page-view time; `swagger-ui.html` references `url: 'api.yaml'` (relative, same
  directory) so the fetched or frozen spec renders without any HTML change.

Generation-side files that previously lived here (`openapi-generate.sh`,
`openapi-merge.json`, `api.base.yaml`, fragment specs, `.tpl` templates) have been
removed — see [Generation tooling lives in the monorepo](#generation-tooling-lives-in-the-monorepo).

## Fetch and fallback contract

The CI workflow runs `scripts/fetch-artifacts.sh` before `zensical build` / `mike
deploy`. The script uses `gh release download` against
`DBRepo-Project/dbrepo` (the DBRepo monorepo) to fetch version-matched release
artifacts, auto-resolving the highest `v<docs_version>.*` patch tag (D-03 tag
normalization). Asset names and destinations are configurable via environment
variables with the provisional defaults defined in `scripts/fetch-artifacts.sh`
(`OPENAPI_ASSET=openapi.yaml` → `OPENAPI_DEST=docs/.openapi/api.yaml`,
`REST_ASSET=rest.md` → `REST_DEST=docs/api/rest.md`,
`PYTHON_ASSET=python-sphinx.tar.gz`).

Per-asset behavior follows the ART-04 error matrix:

- **No matching release on `DBRepo-Project/dbrepo`** → silent fallback: the script
  exits 0 after logging one deterministic line naming the docs version and repo, and
  the build proceeds with the frozen `api.yaml` / `rest.md`.
- **403/429** (auth failure or rate limit) → fail the CI job (D-16). No retry — a 403
  with `GITHUB_TOKEN`'s rate-limit headroom signals a real problem, not a transient
  blip.
- **Missing asset from an otherwise-matching release** → warn and fall back to the
  frozen copy for that asset (D-10 per-asset fallback). A partial release degrades
  gracefully.
- **5xx** → retry, then fail the CI job if retries are exhausted.

Fetched content is ephemeral: `scripts/fetch-artifacts.sh` only overlays files in the
working tree for the current build. It never stages, commits, or pushes. Frozen
copies are the committed git baseline and are updated manually by a maintainer
(verifying the fresh artifact and committing it as the new frozen snapshot) once a
new monorepo release ships (D-17, D-18).

## Generation tooling lives in the monorepo

OpenAPI spec generation, merging, and REST Markdown rendering all run in the
DBRepo monorepo (`DBRepo-Project/dbrepo`), not in this docs repo. The monorepo
publishes the merged `api.yaml` spec as a release artifact; this repo consumes it.
The generation pipeline is defined in `make/gen.mk` of the monorepo and uses tools
that cannot run in a static-site CI:

- `openapi-generate.sh` fetches per-service OpenAPI fragments from running Docker
  services (`docker inspect`, `curl` to service endpoints).
- `openapi-merge-cli` merges the fragments into a single spec via
  `docs/.openapi/openapi-merge.json` (monorepo side).
- `openapi-to-md` renders `rest.md` from the merged spec, using `.tpl` templates
  (`rest.tpl`, `python.tpl`) as the source skeleton.
- Sphinx Python API docs are built via `sphinx-apidoc` + `sphinx-build` from the
  Python source under `lib/python/`.

Per HYG-01 and HYG-02, the historical copies of `openapi-generate.sh`,
`openapi-merge.json`, `api.base.yaml`, and the `.tpl` templates that were committed
to this directory have been removed — they were never runnable in docs CI and only
created the false impression that generation could run here. The docs repo consumes
the merged `api.yaml` (and the rendered `rest.md`, and the built Sphinx HTML) as
release artifacts; it does not generate them.

## Provisional asset names

The asset names used by `scripts/fetch-artifacts.sh` (`openapi.yaml`, `rest.md`,
`python-sphinx.tar.gz`) are provisional per D-01. They are exposed as CI environment
variables with defaults defined in the script, so only a variable changes when the
monorepo finalizes its release-asset naming contract at first release. No workflow
YAML edits are required to rename an asset — set the env var in the dispatching job.