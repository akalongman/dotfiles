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
docker run --rm <image> sh -c 'command -v apk apt-get pip'
```

Hardened and distroless images strip the package manager at the runtime
stage while the upstream Dockerfile still shows it in build stages, so reading
that Dockerfile proves nothing. The check takes seconds; skipping it costs a
failed first deploy (2026-09-11: the n8n 2.x image ships without `apk`; static
binaries copied from a build stage were the fix).
