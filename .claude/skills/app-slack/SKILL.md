---
name: app-slack
description: "Use when searching, reading or writing Slack through the Slack MCP tools (slack_search_*, slack_read_*, slack_send_message, slack_send_message_draft, slack_schedule_message): search modifiers and file filters, message markdown, thread etiquette, reactions, scheduling, and the canvas dialect."
---

# Slack through the MCP bridges

Copied on 2026-10-08 from the `slack-messaging` and `slack-search` skills of
Anthropic's `slack` plugin (claude-plugins-official, version 1.3.0, Apache
License 2.0) and merged into one skill so the plugin could be disabled. The
MCP tools named below are the ones Slack's hosted MCP server exposes through
the per-repo `mcp-remote` bridges (`slack-power-it`, `slack-tsmu`,
`slack-inex`). Block Kit JSON and direct Web API work are out of scope; the
plugin skills that covered them (`block-kit`, `slack-api`) are disabled on
this machine, so re-enable the `slack` plugin if that work ever comes up.

# Part 1: Search

## Search Tools Overview

| Tool                              | Use When                                                                             |
| --------------------------------- | ------------------------------------------------------------------------------------ |
| `slack_search_public`             | Searching public channels only. Does not require user consent.                       |
| `slack_search_public_and_private` | Searching all channels including private, DMs, and group DMs. Requires user consent. |
| `slack_search_channels`           | Finding channels by name or description.                                             |
| `slack_search_users`              | Finding people by name, email, or role.                                              |

## Search Strategy

### Start Broad, Then Narrow

1. Begin with a simple keyword or natural language question.
2. If too many results, add filters (`in:`, `from:`, date ranges).
3. If too few results, remove filters and try synonyms or related terms.

### Choose the Right Search Mode

- **Natural language questions** (e.g., "What is the deadline for project X?"): Best for fuzzy, conceptual searches where you don't know exact keywords.
- **Keyword search** (e.g., `project X deadline`): Best for finding specific, exact content.

### Use Multiple Searches

Don't rely on a single search. Break complex questions into smaller searches:

- Search for the topic first
- Then search for specific people's contributions
- Then search in specific channels

## Search Modifiers Reference

### Location Filters

- `in:channel-name`: Search within a specific channel
- `in:<#C123456>`: Search in channel by ID
- `-in:channel-name`: Exclude a channel
- `in:<@U123456>` or `in:@username`: Search in DMs with a user

### User Filters

- `from:<@U123456>`: Messages from a specific user (by ID)
- `from:username`: Messages from a user (by Slack username)
- `to:<@U123456>`: Messages sent to a specific user
- `to:me`: Messages sent directly to you
- `creator:@username`: Canvases created by a specific person

### Content Filters

- `is:thread`: Only threaded messages
- `is:saved`: Only your saved messages
- `has:pin`: Pinned messages
- `has:link`: Messages containing links
- `has:file`: Messages with file attachments
- `has::emoji:`: Messages with a specific reaction
- `hasmy::emoji:`: Messages you reacted to with a specific reaction

### Date Filters

- `before:YYYY-MM-DD`: Messages before a date
- `after:YYYY-MM-DD`: Messages after a date
- `on:YYYY-MM-DD`: Messages on a specific date
- `during:month`: Messages during a specific month (e.g., `during:january`)

### Text Matching

- `"exact phrase"`: Match an exact phrase
- `-word`: Exclude messages containing a word
- `wild*`: Wildcard matching (minimum 3 characters before `*`)

## File Search

To search for files, set the `content_types="files"` parameter and use a `type:` filter in the query:

- `type:images`, `type:documents`, `type:pdfs`, `type:spreadsheets`, `type:presentations`
- `type:canvases`, `type:lists`, `type:emails`, `type:audio`, `type:videos`

Example: `content_types="files" type:pdfs budget after:2025-01-01`

All the standard modifiers above (`in:`, `from:`, dates, etc.) work with file searches too.

## Useful Parameters

Beyond the query string, the search tools accept parameters that materially improve results:

- `sort`: `score` (relevance, default) or `timestamp` (newest first); pair with `sort_dir` (`asc`/`desc`).
- `content_types`: `messages` (default) or `files`.
- `only_my_channels`: restrict to channels you're a member of.
- `limit`: results per page (capped at 20); paginate with the returned `cursor`.

## Following Up on Results

After finding relevant messages:

- Use `slack_read_thread` to get the full thread context for any threaded message.
- Use `slack_read_channel` with `oldest`/`latest` timestamps to read surrounding messages for context.
- Use `slack_read_user_profile` to identify who a user is when their ID appears in results.
- Use `slack_read_file` to read the contents of a file surfaced by a file search.
- Use `slack_list_channel_members` to see who is in a channel you found.

## Search Pitfalls

- **Boolean operators don't work.** `AND`, `OR`, `NOT` are not supported. Use spaces (implicit AND) and `-` for exclusion. (Repeating the same modifier, e.g. two `from:`, ORs those values together.)
- **Parentheses don't work.** Don't try to group search terms with `()`.
- **Search is not real-time.** Very recent messages (last few seconds) may not appear in search results. Use `slack_read_channel` for the most recent messages.
- **Private channel access.** Use `slack_search_public_and_private` when you need to include private channels, but note this requires user consent.

# Part 2: Messaging

## Formatting

The message tools (`slack_send_message`, `slack_send_message_draft`, `slack_schedule_message`) accept **standard markdown** and convert it to Slack formatting on send. Write normal markdown. Do **not** use Slack's legacy `mrkdwn` syntax (`*bold*`, `~strike~`); those single-character forms mean something different in standard markdown. Each text element is limited to ~5000 characters.

| Format        | Syntax                 |
| ------------- | ---------------------- |
| Bold          | `**text**`             |
| Italic        | `_text_` (or `*text*`) |
| Strikethrough | `~~text~~`             |
| Code (inline) | `` `code` ``           |
| Quote         | `> text`               |
| Link          | `[display text](url)`  |
| Bulleted list | `- item`               |
| Numbered list | `1. item`              |

Block elements also work. Write them as literal markdown:

- **Code block** with an optional language for syntax highlighting:

  ````text
  ```python
  print("hello")
  ```
  ````

- **Table** with `|` delimiters (escape a literal pipe inside a cell as `\|`):

  ```text
  | Feature | Status |
  |---------|--------|
  | Tables  | works  |
  ```

- **Headers** with `#` / `##` / `###`:

  ```text
  ## Section title
  ```

The one thing that does **not** embed in a message: inline images (`![alt](url)`) typically render as a plain link rather than an inline image. For rich embedded layouts (buttons, images, structured cards) you need Block Kit; for a document-style surface where images do embed, use a canvas. See the Notes below.

## Message Structure Guidelines

- **Lead with the point.** Put the most important information in the first line. Many people read Slack on mobile or in notifications where only the first line shows.
- **Keep it short.** Aim for 1-3 short paragraphs (the ~5000-character limit is a ceiling, not a target). If the message is long or structured, consider a Canvas instead.
- **Use line breaks generously.** Walls of text are hard to read. Separate distinct thoughts with blank lines.
- **Use bullet points for lists.** Anything with 3+ items should be a list, not a run-on sentence.
- **Bold key information.** Use `**bold**` for names, dates, deadlines, and action items so they stand out when scanning.

## Thread vs. Channel Etiquette

- **Reply in threads** when responding to a specific message to keep the main channel clean.
- **Use `reply_broadcast`** (also post to channel) only when the reply contains information everyone needs to see.
- **Post in the channel** (not a thread) when starting a new topic, making an announcement, or asking a question to the whole group.
- **Don't start a new thread** to continue an existing conversation; find and reply to the original message.

## Tone and Audience

- Match the tone to the channel: `#general` is usually more formal than `#random`.
- For simple acknowledgments, add an emoji reaction with `slack_add_reaction` instead of a reply message (use `slack_get_reactions` to read existing reactions).
- When writing announcements, use a clear structure: context, key info, call to action.

## Scheduling

- Use `slack_schedule_message` to post later. `post_at` is a Unix timestamp that must be at least 2 minutes in the future and at most 120 days out; the message body uses the same standard markdown as above.
- Scheduled messages can't be edited via the API once set — the user manages them from **Drafts & sent** in Slack.

## Notes

- **Canvas formatting is different.** `slack_create_canvas` uses Canvas-flavored Markdown, a richer dialect than the message tools: headers, tables, checklists, and inline images (`![alt](url)`) all embed, and it also supports user/channel reference cards, callouts, and columns. Do **not** assume the message rules above apply — follow the `slack_create_canvas` tool's own formatting guidance when composing a canvas.
