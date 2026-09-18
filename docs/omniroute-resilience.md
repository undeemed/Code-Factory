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

- Claude seats: `rateLimitProtection: true` with a per-seat cap
  (`maxConcurrent: 5`, `rateLimitOverrides: {maxConcurrent: 5, maxWaitMs: 10000}`),
  `disableCooling: false`
- `modelLockout.errorCodes`: `[404]` — was `[403, 404, 429, 503]`. A 429 is a
  token bucket that refills continuously and a 403 is usually our own burst, so
  neither says the *model* is unusable; only a genuinely absent model does. This
  lives in `/api/settings`, not `/api/resilience`.
- `requestQueue`: `minTimeBetweenRequestsMs: 0` (was 350, an artificial ~171
  req/min ceiling), `maxWaitMs: 10000` (was 30 000)
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

Those 403s did show up in normal fleet operation — both seats sat at
`test_status: banned` for 5.5 h on 2026-09-17 with
`lastError: Request not allowed`, and the client pin was *in step* (2.1.274 both
sides), so a burst was the only remaining cause.

To be precise about what that state is: **`banned` is OmniRoute's own local flag,
not an Anthropic account state.** The accounts were never restricted upstream —
the same seats answered on the first probe the moment the flag was cleared. One
code path sets it (`open-sse/handlers/chatCore.ts`, any error classified
`FORBIDDEN` → `testStatus: "banned"`, `isActive: false`, logged as "disabling
permanently"), and **nothing in the tree ever clears it**. So the cost of a
transient 403 is not a ban; it is a seat that stays out of rotation until a human
notices. That asymmetry is the real defect, and it has two halves:

1. Stop earning the 403 — the moderate per-seat cap, asserted by the posture
   script: `rateLimitProtection: true` plus `rateLimitOverrides` of
   `{maxConcurrent: 3, maxWaitMs: 12000}` on each Claude seat.
2. Stop paying for it after the fact — revive seats whose flag has outlived its
   cause, which `omniroute-resilience-posture.sh` now does for OAuth seats whose
   `rate_limited_until` has passed.

`requestQueue.minTimeBetweenRequestsMs: 0` is *not* needed alongside it, and the
earlier note to pair them was wrong for this shape. The 350 ms floor only binds
when a provider wants more than ~171 requests/minute; at `maxConcurrent: 3` with
4 s agent turns the seat offers ~45/minute, so concurrency binds an order of
magnitude earlier and the floor never fires. Leave the global floor alone —
per-connection `minTime` cannot express 0 anyway (`overrides.minTime > 0` is the
guard, so 0 means "no override").

Verified after applying it: **8 concurrent 400-token requests against one seat
held at exactly 3 `executing`, all 8 returned 200, and neither seat came back
`rate_limited` or `banned`.** The same shape previously produced 5 × 403 and a
~30-minute park.

One upstream trap: per-connection overrides are read only by
`initializeRateLimits()`, which is guarded by a one-shot `initialized` flag, and
`refreshConnectionRateLimits()` — whose doc comment says it is "called after a
PATCH update to `rateLimitOverrides`" — **has no caller anywhere in the tree**.
So a cap written through the API is inert until the container restarts. The
posture script prints the restart line when it changes one.

## 5. Shortening the wait after a seat is limited

Once a seat *is* limited, the reset window belongs to Anthropic and no setting
shortens it. What settings control is how much of that window **you** spend
waiting, and whether the router turns a timer into a block.

The shipped defaults get both wrong:

| setting | shipped | why it hurts |
| --- | --- | --- |
| `connectionCooldown.oauth.useUpstreamRetryHints` | `false` | discards `retry-after` and substitutes a local ladder (5s, 10s, 20s …). Measured live: a seat stating a **54-minute** reset had `rateLimitedUntil` **2 seconds** out. Retrying inside a stated window is what turns a 429 into `403 Request not allowed`. |
| `waitForCooldown.maxRetryWaitSec` | `30` | blocks the request waiting for a cooling seat while a healthy seat idles. |
| `comboCooldownWait` | `90 000 ms` × 5 attempts, `300 000 ms` budget | up to five minutes of dead time per request, for the same reason. |
| `rateLimitProtection` on an OAuth seat | re-seeded `true` | queues locally instead of failing over → `504 … execution expiration`. |

The reviewed posture, asserted by `maintenance/omniroute-resilience-posture.sh`:

```
connectionCooldown.oauth   baseCooldownMs 5000  useUpstreamRetryHints true  maxBackoffSteps 4
connectionCooldown.apikey  baseCooldownMs 3000  useUpstreamRetryHints true  maxBackoffSteps 5
waitForCooldown            enabled  maxRetries 2   maxRetryWaitSec 8
comboCooldownWait          enabled  maxWaitMs 12000  maxAttempts 3  budgetMs 40000
rateLimitProtection        off on every OAuth seat except capped providers
                           (`claude`), which keep it on behind the per-seat cap
per-seat cap                maxConcurrent 5  maxWaitMs 10000  on each capped seat
requestQueue               minTimeBetweenRequestsMs 0  maxWaitMs 10000
providerBreaker.oauth      failureThreshold 12  degradationThreshold 8  resetTimeoutMs 20000
stale local flags          cleared on OAuth seats that are `banned`/`unavailable`
                           with no cooldown left and quiet for 60 s
                           (`OMNIROUTE_SEAT_REVIVE_GRACE_SEC`)
```

Honouring the hint is what makes the wait short, which is the opposite of how it
reads: the exhausted seat is parked for its real window and therefore *skipped*,
so the request fails over to the other seat on the first attempt instead of
queueing behind a seat that cannot answer. Two Claude Max seats are wired
(`Undeemed@icloud.com`, `jerry.x0930@gmail.com`) as separate accounts with
separate windows, so one parked seat is not an outage.

These values live in OmniRoute's **database**, not its container env, and the
server re-seeds part of that table on startup — `rateLimitProtection` has come
back on for the OAuth seats after every recreate so far. Hence an assertion
script wired into `omniroute-bootstrap.sh` rather than a one-time dashboard
click. `--check` reports drift without changing anything.

The client half matters as much: omp's `retry.maxDelayMs` defaults to 300 000,
so it sleeps up to five minutes before giving up on a stated wait. `config/omp.yml`
caps it at 60 000 and pairs it with a fallback chain
(`cc/claude-fable-5-1` → `cc/claude-opus-5` → `auto/best-coding`), so a seat-level
wall becomes a hop, not a nap.

## Timing, derived from Anthropic's own documented semantics

Every number above is chosen against what
[platform.claude.com/docs/en/api/rate-limits](https://platform.claude.com/docs/en/api/rate-limits)
actually specifies, not against a guess about "requests per minute".

| Anthropic's documented behaviour | what it implies for the router | knob |
| --- | --- | --- |
| Limits use a **token bucket**: "capacity is continuously replenished … rather than being reset at fixed intervals" | a pure rate 429 clears in seconds; a fixed 60 s cooldown wastes the window | `baseCooldownMs` 5000 / 3000 |
| `retry-after` is returned on 429, and "**earlier retries will fail**" | never retry inside a stated window; park the seat for exactly it | `useUpstreamRetryHints: true` |
| "You might hit rate limits over shorter time intervals … 60 RPM might be enforced as 1 request per second" | per-minute headroom does not license a burst; arrival shape matters | per-seat `maxConcurrent` |
| 429s also come from **acceleration limits** on "a sharp increase in usage"; the fix is "ramp up your traffic gradually and maintain consistent usage patterns" | a fleet going 0 → 8 concurrent heavy turns is the documented trigger; cap concurrency rather than absorb the 429 | `maxConcurrent: 3` |
| Only **uncached** input counts toward ITPM; `cache_read_input_tokens` do not | failing a turn over to a *cold* seat re-charges the entire prompt as `cache_creation` — the expensive path in both ITPM and dollars | prefer queueing over hopping while a seat is merely busy |
| Cache TTL is 5 minutes, measured **from the start of the request**, and long generations spend it | a local ladder that can wait 640 s (`maxBackoffSteps: 8` → 5 s × 2⁷) lands in a dead zone: too long to keep the cache, too short to match a real 30–60 min seat park | `maxBackoffSteps: 4` (≤ 40 s) |

The resulting split is the point: **queue when a seat is busy, hop when a seat is
parked.** `maxConcurrent: 3` with a 12 s queue keeps a burst on the warm seat
that already holds the cached prefix, while `useUpstreamRetryHints` parks a
genuinely exhausted seat for its stated window so the fallback chain skips it on
the first attempt instead of paying a cold prefix for nothing.

Two caveats on the spend side, both for API-key connections only — a subscription
seat cannot hit them:

- The spend-cap 429 carries **no** `retry-after` and `error.details.error_code`
  `enforced_spend_limit_reached`; access returns at 00:00 UTC on the 1st. No
  cooldown ladder can shorten it, and OmniRoute does not distinguish it, so an
  API-key connection that hits a monthly cap will churn its ladder pointlessly.
- ITPM is estimated at request start and reconciled afterwards, so nothing local
  can pre-compute it.

## Traps found while loosening the gates (2026-09-18)

**A partial ban clear looks like it worked until the container bounces.** The
revival PATCH originally cleared `testStatus`, `isActive`, `errorCode` and
`lastError` — and the seat came back healthy and served traffic. On the next
restart it was `banned` again, with `lastErrorAt` still pointing at the *original*
failure and `lastErrorType: forbidden` left behind. The terminal state is
re-derived from those fields at startup, so revival MUST clear the whole set:
`testStatus`, `isActive`, `errorCode`, `lastError`, `lastErrorType`,
`lastErrorAt`, `backoffLevel`, `rateLimitedUntil`. Verified: after the full
clear, both seats survived a restart *and* the 30 s-delayed
`[CredentialHealth] Testing 6/6 connections` pass with `lastErrorType: null`.

**An empty Claude pool answers 401, not 503.** With one seat banned and the other
still coming up after a restart, ten concurrent requests all returned `401` in
under 200 ms while the log said `[claude] All 1 connection(s) banned by upstream`.
Nothing reached Anthropic. A burst of 401s straight after a restart is a local
pool-empty artifact — check `lastErrorAt` before believing an upstream cause: if
the stamp predates the restart, no new upstream error happened.

**`quotaPreflight` cannot be enabled on this build, and would not help.** Three
independent reasons: `/api/resilience/route.ts` has no `quotaPreflight` branch in
either the GET projection or the PATCH allow-list, so the PATCH is silently
dropped; `autoCombo/*` never references it, so the "master switch for the
auto-routing quota cutoff" is not wired into the scorer; and there is **no quota
fetcher registered for `xiaomi-mimo-token-plan`** (registered: `agentrouter`,
`bailian-coding-plan`, `codex`, `crof`, `deepseek`, `firecrawl`, `freemodel-dev`,
`grok-cli`, `grok-web`, `openrouter`, `qwen-cloud-token-plan`, `v0-vercel`), so
the router cannot read the remaining quota of the one provider that is actually
429ing. Note `/api/settings` and `/api/resilience` both omit keys they otherwise
accept — absence from a GET is not absence from the schema.

**There is no client-side lever that raises an Anthropic limit.** Limits are
computed server-side per organization (*"Limits are set at the organization
level"*), and tier placement is automatic from usage history. The pinned
`claude-cli` identity changes **admission** — a stale pin earns
`403 Request not allowed`, a matching one is accepted — but the seat hit exactly
the same concurrency ceiling either way. So identity shaping cannot buy quota,
and there is no artifact to copy from a higher-throughput setup. The levers that
do move throughput are all legitimate: prompt caching (cache reads are exempt
from ITPM, worth ~5x at a good hit rate — and `cache-health` read `degraded`,
write/read ratio 1.00, until the prompt rewriters were disabled), a second seat
with its own window, a Console account for burst work with no session windows,
and the Batch API for anything non-interactive.

**Cap 5 is measured, not guessed.** 10 concurrent 400-token requests against one
seat held at exactly `executing: 5`, all ten returned 200, and both seats stayed
`active` with no error code. The envelope it sits inside is the earlier
measurement: ~300k tokens in flight per seat (6 × 45k passed, 8 × 45k and
3 × 140k did not). If 403s reappear in normal traffic, drop
`OMNIROUTE_SEAT_CONCURRENCY` back toward 3 rather than removing the cap.

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
