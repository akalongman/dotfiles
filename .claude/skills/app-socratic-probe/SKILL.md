---
name: app-socratic-probe
description: Use when stuck on a design or architecture question and circling, proposing solutions that keep collapsing to the same shape, unable to see past your own assumptions, or when the user keeps saying "that is still the same thinking." Runs a repo-blind, different-model questioning agent that only asks questions (never proposes) to surface the hidden assumption. Precedes brainstorming or planning rather than replacing them. Triggers: "I keep going in circles", "every option looks the same", "socratic", "break my assumptions", "I am stuck on the design".
---

# Socratic Probe

When you are circling on a design question, proposing solutions that keep coming back to the same shape, or cannot see past your own assumptions, run a Socratic probe. A partner agent with deliberately zero codebase context asks short questions that force you to examine your assumptions.

This is a pre-brainstorm, pre-plan activity. Brainstorming and adversarial review assume you have a position to explore or defend. Socratic helps you find the position when every answer feels like a variation of the same wrong thing.

## When to use
- You have proposed three or more solutions that all look the same in disguise.
- The user keeps saying "that is still X thinking" and you cannot see why.
- You can state the problem but every answer feels like a variation of one wrong shape.
- You need to break out of a domain's conventions to see the problem fresh.

Do not use it for problems that just need information (read the code or research instead), or for choosing between two clear options (that is a decision, not a stuck assumption).

## How to run it in Claude Code
1. Spawn the questioner with the Agent tool. Prefer a different model from the one you are running, for a genuinely outside perspective, and set `run_in_background: false` so its question comes back in the same turn.
2. Make it repo-blind. In the prompt, instruct it explicitly: do not read files, do not search or explore the codebase, reason only from the abstract problem in this message. Its value is that it carries none of your context. If a purpose-built no-tools agent type is not available, the instruction in the prompt is what enforces the blindness.
3. It asks one short question. You answer honestly, in your own reasoning or by relaying to the user. To continue the same agent across rounds with its context intact, use SendMessage to its agent id or name. Do not spawn a fresh agent each round.

### Subagent brief
Send one message with exactly two things and nothing else:
1. The abstract problem, stripped of implementation. No file paths, no type names, no framework references.
2. Why you are stuck: what you keep proposing and why it keeps being wrong.

Do not tell it how to behave beyond the role instruction. Just describe the problem. Example brief:

> You are a Socratic questioner. Do not read any files or explore any codebase. Ask me one short question at a time to surface my hidden assumptions. Never propose a solution; only ask.
>
> Problem: we are building a library that lets programs interact with elements on a screen. Every solution we come up with for identifying elements looks like CSS selectors in disguise. We keep reinventing the same pattern.

## Protocol
1. The probe asks one short question. Answer it.
2. It questions your answer. Think harder.
3. Repeat. The agent never proposes, only questions.
4. The user can interject at any point to steer, add context, or challenge an answer. The user is the authority: if they say "that is still wrong," trust them even when you cannot see why.
5. When something breaks open (a new framing, a hidden assumption exposed, a constraint that turns out not to be real), stop and capture the insight.
6. If after ten or more exchanges nothing has broken open, the problem may be genuinely constrained. That is a valid outcome: the design space is smaller than you thought.

## Rules for the stuck party (you)
- Answer honestly. Do not defend previous proposals; examine them.
- When a question makes you uncomfortable, that is where the assumption lives.
- If you catch yourself saying "but we need X because...", question whether you actually need X.

## After the probe
Capture the insight in your working notes before acting on it. Reference it when you move on to brainstorming or planning, so the framing that broke it open is not lost. If you get stuck again later, resume the same agent with SendMessage rather than starting over.
