---
author: Martin Weise
---

# Python API

The DBRepo Python library is a convenience wrapper for data scientists and covers most of the
REST API surface. It is published on [PyPI](https://pypi.org/project/dbrepo/) as `dbrepo`.

## Version matching

Ensure that you use the same Python library version as the target DBRepo instance. For example:
if you see `1.13` in the version selector (bottom left of the docs), install the matching
`1.13.x` Python library:

```bash
pip install dbrepo==1.13.*
```

## Sphinx API reference

> **Sphinx UI not yet available:** The Python API Sphinx reference is published as a release
> artifact from the [DBRepo monorepo](https://github.com/DBRepo-Project/dbrepo). It will be
> served here once the first GitHub release with Python Sphinx assets is cut. In the meantime,
> see the [PyPI page](https://pypi.org/project/dbrepo/) for the API surface.

## Installation

```bash
pip install dbrepo
```

See the [getting started guide](../get-started.md) for a walkthrough.