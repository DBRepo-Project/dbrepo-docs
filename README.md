# DBRepo Web

Website and documentation source for DBRepo, published at <https://dbrepo.github.io/>.

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

The GitHub Actions workflow in `.github/workflows/docs.yml` builds the site on pull requests and pushes to `main`. Pushes to `main` deploy the generated `site/` directory to GitHub Pages.

Repository settings need GitHub Pages configured with "Deploy from a branch: gh-pages" as the source.

## Versioning

The MkDocs configuration keeps `mike` support for documentation versioning. The current deployment workflow publishes the latest built site directly through GitHub Pages actions.

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

## Known Migration Follow-Ups

- Replace hard-coded `/...` links with root-relative or relative links for `https://dbrepo.github.io/`.
- Replace remaining GitLab source URLs in content pages with GitHub URLs.
- Decide whether Python Sphinx HTML should be embedded under `docs/python/` or published as a separate build artifact.
- Revisit `mike` deployment once the desired public URL and version URL layout are finalized.
