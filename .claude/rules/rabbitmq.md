---
name: rules-rabbitmq
description: Apply RabbitMQ and message-queue guidelines for any task that publishes or consumes messages, designs exchange/queue/binding topology, chooses queue types, operates or monitors a broker or cluster, or scripts against rabbitmqadmin.
---

# RabbitMQ Guidelines

Best practices for designing, coding against, and operating RabbitMQ as of
mid 2026. Covers protocol and topology design, client-side reliability patterns,
operational limits, and the `rabbitmqadmin` CLI. This file is protocol and
design guidance. For the local broker's connection facts and service state on
this machine, see `~/.claude/rules/environment.md`; do not duplicate them here.

## When to Activate

Use this file when:

- Publishing to or consuming from RabbitMQ in any language (PHP, Node, .NET,
  Java, Python).
- Designing exchange, queue, and binding topology, or choosing a queue type.
- Operating a broker or cluster: resource limits, clustering, upgrades,
  monitoring, TLS.
- Scripting against a broker (`rabbitmqadmin`, definitions export and import).
- Diagnosing delivery loss, unbounded memory growth, consumer stalls, or
  cluster partition behavior.

## Scope

- In scope: AMQP 0-9-1, AMQP 1.0, MQTT, streams, quorum queues, broker
  operations, client reliability patterns, `rabbitmqadmin`.
- Out of scope: application business logic, and machine-specific connection
  details (those live in `environment.md`).

## Version and support

Target a supported 4.x release for anything new. Treat 3.x as legacy to migrate.

| Series | Status (mid 2026) | Guidance |
|---|---|---|
| 4.3 | Latest stable (4.3.2, Jun 2026) | Use for the newest features. |
| 4.2 | Long-term support (commercial support to 2030) | Preferred for production stability. |
| 4.1 and 4.0 | Community support ended | Upgrade to 4.2 or 4.3. |
| 3.13 and 3.12 | Community support ended (2024) | Do not deploy new. Plan migration. |

Recommendation: pick 4.2 (LTS) for production, or 4.3 when you need the latest
capabilities. Upgrades cross one minor at a time; read the release notes for
each hop and check feature-flag requirements before upgrading.

## Queue types: pick deliberately

Classic is still the default type when `x-queue-type` is unset, so always set it
explicitly. The default is rarely what you want for durable work.

- **Quorum queues** are the default choice for durable, replicated queues. They
  use the Raft consensus algorithm for strong data safety, offer higher
  throughput and lower latency variance than the old mirrored queues, and
  include built-in poison-message handling. Practical minimum is 3 members
  (tolerates one node failure); use odd membership. Budget roughly 32 bytes of
  metadata per message (about 1 MB per 30,000 messages).
- **Streams** are an append-only log for high throughput, large fan-out,
  non-destructive consumption, and replay via offset tracking. Reach for them
  for event-sourcing or log-style workloads. Bound retention explicitly; a
  stream is not infinite storage.
- **Classic queues** are for transient, non-replicated needs only.
- **Classic mirrored queues were removed in RabbitMQ 4.0.** Any `ha-mode` or
  `ha-params` policy is dead configuration. Migrate those queues to quorum.

Set the per-vhost default with `default_queue_type = quorum` so an unspecified
declaration is safe rather than a lone classic queue.

## Reliability: the non-negotiables

Delivery is at-least-once. Safety requires acknowledgements on both ends.

- **Publisher confirms**: enable `confirm.select` and track acks. Handle nacks
  and returned messages (publish `mandatory` and register a return listener).
  Never assume `basic.publish` reached a queue.
- **Manual consumer acknowledgements**: ack only after successful processing.
  Automatic acknowledgement is fire-and-forget and loses in-flight messages if
  the connection drops. Use it only for disposable data.
- **Prefetch (`basic.qos`)**: always set a bounded prefetch. The 100 to 300
  range is the usual sweet spot. A prefetch of 1 throttles throughput badly;
  unbounded prefetch risks unbounded heap growth on both consumer and broker.
- **Idempotent consumers**: redelivery will happen. Deduplicate by message id or
  a business key so reprocessing is safe.
- **Dead-lettering**: configure a dead-letter exchange and rely on the quorum
  delivery-limit (default 20) so a poison message is dead-lettered instead of
  looping forever.
- **Durability**: for anything that must survive a restart, use durable
  exchanges, durable queues, and persistent messages (`delivery_mode = 2`).
  Quorum queues and streams are durable by design.

## Topology as configuration

- Prefer declaring topology through definitions (JSON export and import) or
  policies over ad-hoc declaration at application start, so infrastructure is
  reproducible and reviewable.
- Apply TTL, max-length, dead-letter exchange, and overflow behavior through
  **policies**, not hardcoded per-queue `x-arguments`, so operators can change
  them without an application redeploy. The queue type is the exception: it is
  fixed at declaration time.
- Applications may assert the topology they depend on, but treat production
  topology as owned by definitions and policies.

## Connection and channel hygiene

- Use long-lived connections. Do not open a connection per message or per
  request; connection churn is a leading production problem.
- One channel per thread. Channels are not thread-safe, so never share a channel
  across threads.
- Separate connections for publishing and consuming, so a publisher blocked by a
  memory alarm does not stall consumers.
- Enable automatic connection and topology recovery in the client library.
- Set heartbeats (60s default) and sane per-connection channel limits.

## Operational limits and clustering

From the production checklist:

- **Memory high watermark**: `vm_memory_high_watermark.relative` between 0.4 and
  0.7 (0.6 default). Above 0.7 only with solid memory monitoring in place.
- **Disk free limit**: set `disk_free_limit` at least equal to the memory
  watermark size. The 50 MB default is for development only. A node out of disk
  is a serious incident.
- **File descriptors**: at least 50,000 for production. Size as (95th percentile
  concurrent connections times 2) plus the total queue count.
- **Clustering**: use odd node counts (3, 5, 7) for a clear majority. Set
  `cluster_partition_handling = pause_minority`. Synchronize node clocks with
  NTP.
- **Metadata store**: Khepri, the Raft-based metadata store, is the default in
  newer 4.x clusters (4.1 onward) and replaces Mnesia. It makes schema changes
  safer during partitions. Verify which store a given deployment uses before
  assuming.
- **Monitoring**: scrape the Prometheus endpoint (`rabbitmq_prometheus` plugin)
  and the management API. Watch queue depth, unacknowledged count, consumer
  utilisation, memory and disk alarms, and file-descriptor usage.

## Security

- Never expose the default `guest` user off loopback. Create per-application
  users with least privilege scoped to specific vhosts.
- Isolate applications and environments with vhosts.
- Use TLS for client and inter-node traffic on untrusted networks, with peer
  verification enabled.
- Restrict the management UI and API. Do not reuse an admin account for
  applications.

## rabbitmqadmin CLI

`rabbitmqadmin` drives the broker over the HTTP API, which makes it the right
tool for automation, provisioning, and readiness checks. There are two
incompatible generations.

- **v2** is the current, actively developed standalone native binary with its
  own release cycle. It supports RabbitMQ 4.x plus 3.12 and 3.13. Use it for new
  automation.
- **v1** is the legacy Python script bundled with the management plugin and is no
  longer developed. Its syntax differs and is not compatible with v2.

v2 syntax rules that commonly trip people up:

- Global flags go **before** the command group: `rabbitmqadmin --vhost events
  queues declare ...`.
- Flags are `--snake-case` with explicit values (`--auto-delete true`), not the
  v1 `auto_delete=true` key=value style.
- Connection aliases live in a TOML config file, not v1's INI format.

Command groups: `queues`, `exchanges`, `bindings`, `streams` (queuing); `users`,
`permissions`, `vhosts` (access control); `nodes`, `channels`, `connections`,
`consumers`, `health_check` (monitoring); `policies`, `operator_policies`;
`federation`, `shovels`, `definitions`, `parameters`; `feature_flags`,
`plugins`, `show`.

Useful v2 commands:

```bash
# Declare a durable quorum queue in a vhost
rabbitmqadmin --vhost events queues declare --name orders --type quorum --durable true

# List queues, connections, consumers
rabbitmqadmin queues list
rabbitmqadmin connections list

# Apply a policy (dead-letter exchange plus a length cap)
rabbitmqadmin policies declare --name orders-dlx --pattern '^orders' \
  --definition '{"dead-letter-exchange":"dlx","max-length":100000}' --apply-to queues

# Back up and provision topology
rabbitmqadmin definitions export --file broker.json
rabbitmqadmin definitions import --file broker.json

# Health checks for CI and readiness probes
rabbitmqadmin health_check cluster_wide_alarms
```

Use `publish` and `get` only for testing and debugging, never as an application
transport. `basic.get` polling is an anti-pattern; real consumers use push
delivery.

## Anti-patterns

- `basic.get` polling instead of a push consumer.
- Automatic acknowledgement for messages that matter.
- Unbounded prefetch (no `basic.qos`).
- A connection or channel per message or per request.
- Sharing one channel across threads.
- Relying on classic mirrored queues or `ha-mode` policies (removed in 4.0).
- Encoding TTL, dead-letter, or length limits as per-queue `x-arguments` that
  operators cannot change without a redeploy. Prefer policies.
- Using RabbitMQ as a database or for long-term storage. If you need replay, use
  a stream with explicit, bounded retention.
- Large numbers of short-lived queues and bindings (topology churn).

## Laravel integration

Laravel's Horizon supervises Redis-backed queues only. To back the queue on
RabbitMQ, use a maintained AMQP queue driver (for example
`vladimir-yuldashev/laravel-queue-rabbitmq`) and apply everything above: quorum
queues, manual acknowledgements, publisher confirms, and bounded prefetch. Model
retries and failures through a dead-letter exchange and the quorum delivery
limit rather than tight in-application redelivery loops.
