# DBRepo Web

Website and documentation source for DBRepo, published at <https://dbrepo-project.github.io/dbrepo-docs/>.

This repository currently hosts the migrated MkDocs documentation from the DBRepo monorepo. It is intended to grow into the public DBRepo website while keeping the documentation build independent from application code.

## Local Development

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/zensical serve
```

Build the static site:

```bash
.venv/bin/zensical build
```

## Deployment

The GitHub Actions workflow in `.github/workflows/docs.yml` builds the site on pull requests and pushes to `main`. Pushes to `main` run `mike deploy --push`, which updates the `gh-pages` branch that GitHub Pages serves.

Repository settings need GitHub Pages configured with "Deploy from a branch: gh-pages" as the source.

## Versioning

The Zensical configuration keeps `mike` support for documentation versioning. The current deployment workflow publishes version `1.13` and the `latest` alias to the `gh-pages` branch.

For manual versioned publishing, use:

```bash
.venv/bin/mike deploy --push 1.13 latest
.venv/bin/mike set-default --push latest
```

## Generated Artifacts

The initial migration includes generated documentation artifacts copied from the monorepo:

- `docs/api/rest.md`
- `docs/.openapi/api.yaml`
- `docs/.openapi/swagger-ui.html`

Future releases should publish these from the DBRepo application repository as release artifacts, then consume them here during the website build.

## Migration Status

- Root-relative documentation links were remediated for mike versioned paths.
- Active GitLab source URLs were migrated to GitHub; historical changelog links intentionally remain on GitLab.
- OpenAPI and Python API documentation artifacts are fetched from GitHub releases when available, with committed frozen fallbacks.
- Scheduled external link checking and site-root `llms.txt` are configured.
