---
name: time-skill
description: Display the current time in Georgian Standard Time (UTC+4). Use when the user asks for the current time or Georgian time.
user-invocable: true
agent: time-agent
---

# Time Skill

This skill displays the current date and time in Georgian Standard Time.

## Task

Display the current date and time in Georgian Standard Time (UTC+4).

## Instructions

1. Use the `time-agent` subagent (via the Agent tool with `subagent_type: "time-agent"`) to fetch and display the current time in Georgian Standard Time.
2. Display the result returned by the agent to the user.
