---
name: app-pdf-doc
description: Use when the user wants a partner-facing or external-facing PDF document, such as an API contract, integration guide, incident summary, or migration notice addressed to an external team, partner company, or third-party developers.
argument-hint: [topic and audience, e.g. "payment API contract for partner devs"]
---

# Partner-Facing PDF Documents

Produce a polished PDF an external party will read and judge the company by. One fixed neutral format, strict content boundary, two to three pages.

## Workflow

1. **Classify** the document and use its section recipe:
   - **API contract**: Overview, endpoint signature (table), payload contract (example + field table), behavioral notes, "Required from you", draft banner.
   - **Integration guide**: Overview, prerequisites, step flow, endpoints, examples, troubleshooting.
   - **Incident summary**: Impact, timeline, cause (external-safe), remediation, contact.
   - **Migration notice**: What changes, dates, action required, compatibility.
2. **Gather** facts: conversation first, then repo sources. If an OpenSpec change is involved, read its `summary.md` and `proposal.md` as raw material. Verify every endpoint, field, and status code against actual code (routes, request classes, validation rules). Example values shown to the partner (response messages, status strings) must be copied literally from code or lang files, never paraphrased. Never invent. If a fact is missing, ask the user; do not fabricate.
3. **Apply the boundary filter** (below), rewriting everything for the external reader in present tense.
4. **Render**: read `template.html` from this skill's directory, fill the placeholders (`{{TITLE}}`, `{{META}}`, `{{BODY}}`, `{{DOC_NAME}}`, `{{DATE}}`), write to a temp file, then:
   ```bash
   google-chrome --headless --disable-gpu --no-sandbox --no-pdf-header-footer \
     --print-to-pdf=<repo>/docs/<topic-slug>.pdf /tmp/<topic-slug>.html
   ```
   Fall back to `chromium`. If neither exists, stop and tell the user to install one. Verify with `pdfinfo` when available.
5. **Deliver**: send the PDF to the user. Do not commit it unless asked.

## Boundary filter: never crosses the company line

| Never include | Use instead |
|---|---|
| Env var names, config storage formats ("comma-separated list", "fail-closed setting") | "pre-registered with us", "must be agreed in advance" |
| Internal codenames of providers/systems beyond what the contract exposes | "the bank", "the payment provider" (raw status keys that ARE the contract may stay) |
| Internal recovery/ops mechanics (reconciliation jobs, queues, logging, monitoring, Sentry/Horizon) | Describe only the externally observable guarantee |
| Risk acceptance, effort estimates, timing framing from internal docs | Omit |
| Credentials, tokens, internal hostnames | Placeholders like `{api_token}` |
| Invented metadata: version numbers, "confidential" classifications, legal disclaimers | Only the date and a Draft/Final status the user confirmed |

When a fact's partner visibility is uncertain (e.g. an internal multiplier that changes what the partner observes), ask the user before including or omitting it.

## Format rules

- Two to three pages. If the draft runs longer, cut subsections, not table rows.
- The template's style is fixed. Do not add CSS, colors, or logos.
- Status line says `Draft for confirmation` until the user explicitly says the contract is final.
- Unconfirmed contracts also get the `<div class="note">` draft banner from the template.
- Plain prose, no dashes as punctuation, short sentences, tables for enumerable facts, field names and status values in `<code>`.
- End contracts with a "Required from you" numbered list so the partner knows what to send back.

## Common mistakes

- Documenting internal config mechanics because they explain a 422. The partner needs "host must be pre-registered", not how we store the list.
- Inflating to 5+ pages with invented sections (versioning, classification, guarantees summary). Predictable and short beats exhaustive.
- Copying OpenSpec `summary.md` text verbatim. It is written for internal stakeholders; rewrite for the partner.
- Hand-rolling new CSS. The template is the format; consistency across documents is the point.
