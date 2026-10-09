---
name: rules-docker
description: Apply when writing or editing Dockerfiles, compose files, or container build steps.
paths:
  - "**/Dockerfile"
  - "**/Dockerfile.*"
  - "**/*.dockerfile"
  - "**/docker-compose*.y*ml"
  - "**/compose*.y*ml"
  - "**/.dockerignore"
---

# Container Build Rules

## Confirm the package manager before installing on a third-party image

Before writing a layer that installs packages on top of a third-party image
(`RUN apk add`, `apt-get install`, `pip install`), run the pinned image once
and confirm the package manager exists:

```bash
docker run --rm <image> sh -c 'for t in apk apt-get pip; do printf "%s: " "$t"; command -v "$t" || echo missing; done'
```

Hardened and distroless images strip the package manager at the runtime
stage while the upstream Dockerfile still shows it in build stages, so reading
that Dockerfile proves nothing. The check takes seconds; skipping it costs a
failed first deploy (2026-09-11: the n8n 2.x image ships without `apk`; static
binaries copied from a build stage were the fix).

Check one name per `command -v` and print `missing` for each absent one. On
Debian-based images `sh` is dash, and `command -v apk apt-get pip` with several
names printed nothing for `node:24-trixie-slim`, which has `/usr/bin/apt-get`
(2026-10-09). An empty answer must never be read as "no package manager".
