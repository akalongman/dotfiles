---
description: Use when checking whether OpenAPI API documentation still matches the real backend implementation, or when API docs may be stale or have drifted from the code. Detects mismatches between documented endpoints, request fields, response shapes, permission scopes, query filters, and status codes versus the actual routes, validation rules, resources, and policies. Targets OpenAPI documentation with a Laravel backend. Takes an optional module name; with no argument it verifies every module.
user-invocable: true
---

# Verify API Docs Against Implementation

## Overview

Read-only verifier that detects drift between OpenAPI documentation and the real backend code. It compares the documented contract (paths, methods, auth scopes, request bodies, query parameters, response shapes, status codes) against what the implementation actually accepts and returns, then reports every mismatch. It never edits files.

This is semantic verification, not structural validation. A structural lint (bundling and linting the OpenAPI files) only proves the documents are well formed. This skill proves the documents describe the real behavior.

## When to use

- Verifying that API docs match the code after a feature lands, before a release, or during review.
- Hunting for stale docs: a documented field the code rejects, an attribute the code never returns, a permission that moved, a filter that no longer exists.

When NOT to use: pure structural validation of the OpenAPI files. Run the project's own docs bundle and lint task for that.

## Input

`$ARGUMENTS` is an optional module name.

- With a module name: verify only that module, inline.
- With no argument: run the full sweep across every module, one subagent per module.

## Step 0: discover layout and preconditions

Do not hardcode any path. Discover the project shape first.

1. Locate the OpenAPI root. Search for an entry document with an `openapi:` key, or a `paths.yaml`, `main.yaml`, or `openapi.yaml` under a `docs` or `api` directory. Handle both single file specs and split specs that use `$ref` into per-endpoint and per-component files.
2. Confirm the backend is Laravel (an `artisan` file and a `routes/` directory exist). If there is no OpenAPI root or no Laravel app, stop and report that this skill targets OpenAPI documentation with a Laravel backend.
3. Build the module list. A module is one top-level grouping of endpoints. Derive it from the endpoint directory names (the subdirectories that hold the endpoint YAMLs), falling back to the OpenAPI `tags`. Each module includes its sub-resources.

## Module resolution

Match `$ARGUMENTS` case-insensitively against the endpoint directory names, then the tags, then the route URL prefix. Resolve to the set of endpoint YAMLs, the index paths that reference them, the matching routes, and the controllers, FormRequests, Resources, and Policies those routes use. Include sub-resources (for example an orders module also covers its items, shipments, and refunds).

## Execution

- Single module: run the Verification Protocol below inline for the resolved module, then emit the report.
- Full sweep (no argument): dispatch one read-only subagent per module, all in a single parallel batch. Give each subagent the Verification Protocol, the Finding record format, and the Severity definitions, with its `MODULE` set, and require it to return three things: the structured findings list (one record per finding), a `COUNTS:` line, and a one-line coverage note stating which dimensions it checked and which came back clean. Then synthesize the combined report. Each subagent is read-only: it inspects via route listing, file reads, and grep, and makes no edits. For the dispatch mechanics use superpowers:dispatching-parallel-agents.

A shared, explicit protocol is the point of this skill. Without it, parallel subagents each improvise a different method and produce reports that cannot be synthesized. Every subagent runs the same six checks and returns the same finding shape.

## Verification Protocol

Build the endpoint inventory first, then check every documented operation against the code, one path plus method at a time so nothing is skipped.

Authoritative route table: run `php artisan route:list --json` and filter to the module prefix. This gives the real HTTP methods, the resolved URIs and path parameter names, the `Controller@action`, and the middleware stack. Prefer this over reading the routes file by eye.

For each documented operation (one HTTP method on one path), locate its route, the controller action, the FormRequest(s) that action type-hints, the Resource it returns, and the Policy or permission check it runs. Then run all six checks. Report drift in both directions: documented but absent in code, and present in code but undocumented.

**D1 Endpoints and methods.** Every documented path plus method has a matching route, and every route under the module is documented. Flag missing routes, undocumented routes, method mismatches (for example documented PATCH versus routed PUT), and path parameter name mismatches.

**D2 Permissions (best-effort).** Discover how the project encodes auth scopes first (a common shape is `{resource}:{action}`, sometimes with a suffix variant). Confirm each documented scope maps to a real permission definition in the code (constants, enum cases, or a seeded permission list) and that a matching Policy ability exists for the action. Flag scopes that are malformed or have no backing permission definition or Policy ability. Static analysis cannot prove exact runtime enforcement, so state this dimension as best-effort.

**D3 Request body.** Compare the documented request payload (its properties and its `required` list) against the FormRequest validation rules. Many projects use one save request that branches on create versus update, so resolve required versus optional per method. Check field presence both ways, required versus optional or sometimes, type (integer, string, uuid, boolean, number), nullable (a documented `["T","null"]` type lines up with a `nullable` rule), and enum membership.

**D4 Query parameters and filters.** Compare documented query parameters and `filters[...]` keys against the rules that validate them and the repository or service code that applies them. Critical rule: if the project's base FormRequest rejects unknown fields (an extra-attribute guard), then any documented query or body parameter absent from the rules is rejected at validation time (a 422), not silently ignored. Treat a documented but unvalidated parameter as contract-breaking, not cosmetic. Also flag a parameter the controller reads but the request layer forbids (a dead parameter), and filters handled in code but undocumented.

**D5 Response shape.** Compare the documented response resource (its `attributes` and `relationships`) against what the Resource class actually projects. Resolve role or context variants (for example an admin shape versus a public shape the same Resource emits conditionally). Confirm each documented relationship has a real include path. Verify the exact key names for pivot or meta blocks against the Resource code (often produced by an append or with mechanism) rather than assuming, and ground-truth a non-obvious shape against an integration test assertion when one exists. Flag documented attributes the code never emits and emitted attributes that are undocumented.

**D6 Status codes.** Sanity check the documented response codes against the controller and the shared response helpers (for example create returns 201). Flag a documented code the code cannot reach (for example a conflict path that is commented out) and response `$ref` typos (for example a 404 entry pointing at the 403 schema file).

## High value checks (easy to miss)

- An extra-attribute guard turns a documented but unvalidated parameter into a 422.
- Pivot versus meta key names in relationship payloads come from the Resource, not from convention.
- Dead parameters: the controller reads a value the request layer rejects.
- Documented status codes that current code cannot produce.
- Response `$ref` typos that wire the wrong schema.
- Enum values in the docs must match the model or enum constants exactly.

## Finding record

Record every finding with these fields:

- **Severity** (see below).
- **Dimension** (D1 through D6).
- **Endpoint** (HTTP method and path).
- **Doc location** (`file:line`).
- **Code location** (`file:line`).
- **Doc says vs Code does** (the concrete values on each side).
- **Likely stale side** (doc or code), stated as a judgement, not an assumption that code is always right.
- **Recommendation** (the smallest change that resolves the drift).

## Severity

- **Critical**: the documented contract is wrong in a way that breaks a client. Missing or undocumented route, method mismatch, a documented field rejected by validation, a documented attribute the code never returns, a malformed or unbacked permission scope.
- **Warning**: a real mismatch that does not fully break a client. Type, required, or nullable mismatch, an undocumented field or filter, a documented but unreachable status code.
- **Info**: cosmetic or descriptive drift. Description, summary, or example differences, a `$ref` typo, ordering.

## Report

Never edit files. Print the report.

Every report states coverage: which dimensions (D1 through D6) were checked and which came back clean, so a clean dimension is never confused with a skipped one. A dimension with no findings is reported as clean, not omitted.

- **Single module**: a one-line coverage note, then the findings grouped by severity, highest first.
- **Full sweep**: lead with a summary table (one row per module with the count at each severity and a short verdict), then a section per module with its coverage note and findings.

After the report, offer to write it to a file. Do not write one unless asked.

## Common mistakes

- Reading the routes file instead of `route:list --json`, then missing resolved path parameter names and the middleware stack.
- Checking only documented-but-missing drift and forgetting the reverse (code present but undocumented).
- Producing freeform output per subagent on a full sweep, which cannot be synthesized. Use the Finding record and Severity model for every module.
- Omitting clean dimensions, so a reader cannot tell a checked dimension from a skipped one.
