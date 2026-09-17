# OmniRoute resilience gates: why Fable and Opus "never work"

Four independent OmniRoute gates each turn healthy Claude traffic into a hard
error, and every one of them is triggered by exactly the request shape a coding
agent produces: a big context with tool schemas. None of them are Anthropic rate
limits, though three of them *masquerade* as one. This is the record of what they
are, how to recognise each from its error string, and what they are set to now.

All of it was diagnosed on 2026-09-17 against `diegosouzapw/omniroute:main`
(app 3.8.50) on the box.

## Recognise the gate from the error

| error the client sees | gate | it is NOT |
| --- | --- | --- |
| `503 chat_admission_busy … retry-after-ms=2000` | heavyweight admission lease | upstream capacity |
| `504 Request exceeded OmniRoute's local rate-limit execution expiration` | local Bottleneck queue (`maxWaitMs`) | upstream timeout |
| `Provider returned empty content` → omp `Assistant returned empty stop after retry cap` | prompt-rewriting compression | model refusing to answer |
| `403 Request not allowed` → `All N connection(s) banned by upstream` | retry storm consequence of the above, then auto-ban | a banned account |

The trap: the first three manufacture the fourth. A local 504 was in
`modelLockout.errorCodes`, so a queue expiry locked the model; with cooldowns
disabled the router retried immediately; the retry storm earned a real upstream
`403`; the router treats a 403 as a permanent ban and drops the connection. The
visible symptom is "my Claude Max account is banned", and the cause is three
local settings.

## 1. Heavyweight admission lease (`503 chat_admission_busy`)

`src/shared/middleware/chatBodyAdmission.ts` classifies a request **heavy** when
ANY of these holds:

| threshold | env | default |
| --- | --- | --- |
| body bytes | `OMNIROUTE_CHAT_LARGE_BODY_BYTES` | 256 KB |
| message count | `OMNIROUTE_CHAT_HEAVY_MESSAGE_COUNT` | 200 |
| tool count | `OMNIROUTE_CHAT_HEAVY_TOOL_COUNT` | 64 |
| estimated tokens | `OMNIROUTE_CHAT_HEAVY_ESTIMATED_TOKENS` | **32 000** |

Only `OMNIROUTE_CHAT_MAX_HEAVY_IN_FLIGHT` heavy requests may be in flight
**router-wide** (default **1**); a second waits
`OMNIROUTE_CHAT_ADMISSION_QUEUE_MS` (default 2 s) and is then shed with a
retryable 503. The router's own comment names the trigger: *"coding-agent
fan-out is the common trigger"*.

Token estimation is `conservativeStringTokens`: **0.25 tokens per ASCII
character**, i.e. `chars / 4`. So a 180 000-character body is 45 000 estimated
tokens and heavy under the default.

This is why the failure looked model-specific. A real omp turn on a repo is
26–57 k tokens with 13 tool schemas, so **every** Fable/Opus turn was heavy and
fought for a single lease, while `smol`/`tiny` prompts on MiMo stayed under the
bar and never tripped it. Nothing about Claude was special.

The lease is a heap guard: parked waiters hold fully buffered bodies, and the
container shipped a 1 GB node heap. Raising concurrency without raising the heap
just trades 503s for an OOM, so both move together.

## 2. Local rate-limit queue (`504 … execution expiration`)

`rateLimitProtection` per connection enables an adaptive Bottleneck limiter.
From `open-sse/services/rateLimitManager.ts`:

> Default: ENABLED for API key providers (safety net), **DISABLED for OAuth**.

Both Claude Max (OAuth) seats had it **on** — non-default — so Claude was the
only provider with a local queue in front of it. With
`minTimeBetweenRequestsMs: 350` and a per-connection `maxConcurrent`, the fleet's
lanes queued until `requestQueue.maxWaitMs` (30 s) expired: `504`.

`maxQueueDepth: 0` is **disabled, i.e. an unbounded queue** — not "no room to
wait" (`rateLimitManager/admission.ts`: *"Default `0` = disabled, preserving
today's behavior"*). Unbounded queueing is what let requests live long enough to
hit the expiry. Setting it `> 0` makes bursts fail fast with
`RATE_LIMIT_QUEUE_FULL` instead of hanging 30 s — a better failure shape, but a
separate decision.

Measured: Claude 4.5/4.2/3.5 s per request versus MiMo 4.0/4.8/12.1 s. Claude was
*faster* than MiMo, so per-request latency was never the difference — only the
queue was.

`PATCH /api/providers/{id}` **cannot** flip this flag; the route ignores it by
design (guard for upstream #11278). Use the endpoint that owns it, which also
syncs the in-memory limiter:

```bash
curl -X PATCH -b cookies "$OMNIROUTE_DASHBOARD/api/rate-limits" \
  -H 'Content-Type: application/json' \
  -d '{"connectionId":"<id>","enabled":false}'   # POST also accepted
```

## 3. Prompt-rewriting compression (`Provider returned empty content`)

The `caveman` and `rtk` engines rewrite the prompt before dispatch. On tool-heavy
Claude turns the rewritten payload came back as an **empty stream**, which omp
retries three times and then reports as `Assistant returned empty stop after
retry cap`. Every empty-content event in the log was immediately preceded by a
`COMPRESSION` line; disabling the two engines took empty-content from 15 in 8
minutes to **0**.

What they were buying, from the router's own log:

```
57387 -> 56369 tokens (1.77% saved, techniques: …rtk-filter, caveman-rules)
26275 -> 26267 tokens (0.03% saved, techniques: caveman-rules)
```

**0.03–1.77%** — while rewriting the prompt prefix on every request
(`autoTriggerTokens: 0`), which defeats Anthropic prompt caching, where cache
reads bill at roughly a tenth of input. `GET /api/usage/cache-health` agreed:
`verdict: degraded`, write/read ratio 1.00, 122 heavy-write calls carrying ~100 %
of write tokens. Turning the rewriters off should *lower* spend, not raise it.

Engines are toggled independently of `stackedPipeline` — removing `caveman` from
the pipeline while `engines.caveman.enabled` stays true keeps applying it (the
log still listed `caveman-rules`). Disable the engine, not just the pipeline
entry.

## 4. Auto-ban on 403, and the settings that feed it

- `modelLockout.errorCodes` included `502` and `504`. A **local** queue expiry
  therefore locked the model. Removed both: a local timeout says nothing about
  the model.
- `providerSpecificData.disableCooling: true` ("Disable cooldown for this
  connection") was set on both Claude seats, so recoverable errors were retried
  with no backoff — the retry storm that earns a real 403.
- A connection is skipped **before dispatch** when `test_status` is `banned` or
  `unavailable`, or while `rate_limited_until` is in the future, independently of
  `is_active`, and nothing clears `banned` automatically:

```bash
curl -X PATCH -b cookies "$OMNIROUTE_DASHBOARD/api/providers/<id>" \
  -H 'Content-Type: application/json' \
  -d '{"isActive":true,"testStatus":"active","errorCode":null,"lastError":null}'
```

Do not "test" a disabled connection with `POST /api/providers/{id}/test`: it
activates the connection as a side effect.

## Current configuration

Container env (`maintenance/omniroute-bootstrap.sh` owns these):

```
OMNIROUTE_CHAT_MAX_HEAVY_IN_FLIGHT        1     -> 6
OMNIROUTE_CHAT_HEAVY_ESTIMATED_TOKENS     32000 -> 45000
OMNIROUTE_CHAT_ADMISSION_QUEUE_MS         2000  -> 20000
OMNIROUTE_CHAT_ADMISSION_MAX_QUEUED_BYTES 4MB   -> 32MB
OMNIROUTE_MEMORY_MB / --max-old-space-size 1024 -> 3072
```

The heavy bar sits at 45 k **inside** the 26-57 k band real turns occupy, not
above it. That is deliberate: ordinary turns pass freely, while the larger half
still takes a lease, so the gate keeps bounding concurrent huge-context bursts
against the heap. Raising it past the traffic it is meant to bound (128 k was
tried) removes admission control from the fleet's actual requests and trades
503s for an OOM risk.

Measured under load: 8 concurrent ~50 k-token requests (each above the bar, so 2
waited on the 6-lease gate and passed inside the 20 s window) all served, with
heap peaking at **920 MiB of the 3 GB ceiling**.

Dashboard/DB settings:

- Claude seats: `rateLimitProtection: false`, `maxConcurrent: null`,
  `disableCooling: false`
- `modelLockout.errorCodes`: `[403, 404, 429, 503]`
- compression: `caveman` and `rtk` engines disabled, `defaultMode: off`,
  `autoTriggerMode: off`

## The real Claude ceiling

With every local gate out of the way, Anthropic's own limit appears — and it is
about **concurrency**, not volume:

```
6 concurrent x ~45k tokens  -> 6/6 ok
8 concurrent x ~45k tokens  -> 3 ok, 5 x 403 "Request not allowed (reset after …)"
3 concurrent x ~140k tokens -> 3 x "Unavailable (reset after 33m 26s)"
```

So one Claude Max seat sustains roughly **3–4 concurrent heavy agent turns**.
Above that Anthropic answers `403 Request not allowed` with a reset window, and a
burst of very large requests parks the seat for ~30 minutes. Note this means a
403 is not automatically proof of a ban — check whether a burst preceded it.

If those 403s show up in normal fleet operation, the correct response is a
*moderate* per-seat cap, not the shipped one: re-enable `rateLimitProtection`
with `maxConcurrent: 4` **and** `requestQueue.minTimeBetweenRequestsMs: 0`. The
350 ms floor is what made the original limiter starve — it caps a provider at
~171 requests/minute regardless of `concurrentRequests: 120`.

## Writable-layer patches

Two fixes live in the container's writable layer and are lost on `docker rm` or
an image pull, but survive `docker restart`:

- `maintenance/omniroute-system-role-patch.sh` — keeps `system` as `system` in
  the chat→Responses translator, which `cloud.zed.dev` requires.
- `maintenance/omniroute-claude-client-version.sh` — keeps the pinned
  `claude-cli` identity in step with the installed CLI; a stale pin earns
  `403 Request not allowed` on its own.

`maintenance/omniroute-bootstrap.sh` provisions or recreates the container with
the env above and re-applies both, then verifies. Run `--recreate` after any
`docker pull`; verify any time with:

```bash
maintenance/omniroute-bootstrap.sh --check
```

## Diagnostic recipes

```bash
# which gate is firing
sudo docker logs omniroute --since 10m 2>&1 | grep -cE 'chat_admission_busy'
sudo docker logs omniroute --since 10m 2>&1 | grep -c 'local rate-limit execution expiration'
sudo docker logs omniroute --since 10m 2>&1 | grep -c 'empty content'
sudo docker logs omniroute --since 10m 2>&1 | grep -c 'Request not allowed'

# per-provider egress health (ProxyEgress is a log tag, not a configured proxy)
sudo docker logs omniroute --since 10m 2>&1 | grep -oE '\[ProxyEgress\] [a-z-]+ status=[a-z]+' | sort | uniq -c

# what compression actually saved, and whether it is mangling anything
sudo docker logs omniroute --since 10m 2>&1 | grep COMPRESSION | tail -5

# seat health and limiter state
curl -s -b cookies "$OMNIROUTE_DASHBOARD/api/rate-limits" | jq '.[] | {provider,enabled,queued,running}'
```

A model resolving to a strange provider (`ROUTING opus-5 → notion-web/opus-5`,
then `401 No active credentials for provider: notion-web`) means a **bare model
id fell through to registry resolution** — the named combo or model no longer
exists. `blockedProviders` does not prevent it; only removing the dead reference
does. See [model selection](omniroute-models.md).
