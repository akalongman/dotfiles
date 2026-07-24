---
description: Review a GitLab or GitHub project by cloning the repository and reading entire project
user-invocable: true
---

Review a project thoroughly by reading entire project.

**Input:** `$ARGUMENTS` — GitLab/GitHub URL.

**Steps:**

1. Detect the platform:
   - If `$ARGUMENTS` contains `gitlab.com` or looks like a GitLab URL → GitLab
   - If `$ARGUMENTS` contains `github.com` or looks like a GitHub URL → GitHub

2. Locate or clone the repository:
   - If the current working directory is already a checkout of the target repository (`git remote get-url origin` matches `$ARGUMENTS`), review it in place and skip cloning.
   - Otherwise ask the user for their projects path (the directory where clones should live), then clone into it:
     - **GitLab:** `glab repo clone <namespace/repo> <projects-path>/{namespace}/{repo}`
     - **GitHub:** `gh repo clone <owner/repo> <projects-path>/{owner}/{repo}`
   - If that target directory already contains the clone, reuse it and pull the default branch instead of recloning.

3. Read every project file in full using the Read tool, skipping vendored and generated content (`vendor/`, `node_modules/`, `dist/`, lock files).

4. For each reviewed file, also identify and read the related base classes, interfaces, and parent classes that are relevant to understanding the code (e.g. base Policy, base Service, base Repository, base Controller, model, contracts). Read these too.

5. Write the review. Structure it as:

    **Already flagged** — issues already noted in existing comments (acknowledge but do not duplicate).

    **Additional issues** — new issues you found, each with:
    - File path and line reference
    - Clear description of the problem
    - Concrete suggestion for the fix

    **Positives** — what is done well.

    Be critical and specific. Do not praise generic things. Focus on correctness, architecture consistency with the rest of the codebase, adherence to project patterns, security, and test quality.
