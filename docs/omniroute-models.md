# omp model selection through OmniRoute

OmniRoute (`diegosouzapw/omniroute`, port 20128 on the box) is the only model
catalog omp uses. This document records the contract, because the obvious
configurations are all wrong in ways that fail silently.

## Contract

**One omp option per exact model, fanned across every account/key that serves
it.** Each option is an OmniRoute *combo* whose name is the model
(`opus-5`, `sonnet-5`, `gpt-5.6-terra`, …) and whose members are that same model
on each key:

```
sonnet-5       cc/claude-sonnet-5        zed-hosted/claude-sonnet-5
gpt-5.6-terra  cx/gpt-5.6-terra          zed-hosted/gpt-5.6-terra
opus-5         cc/claude-opus-5          (fans across every active claude connection)
```

A combo name that shadows a real model id is the router's documented mechanism
for per-model provider fallback (`docs/routing/AUTO-COMBO.md`, upstream #6940).

`scripts/sync_omniroute_models.py` turns those combos into the `omniroute`
provider block of `~/.omp/agent/models.yml`. Never hand-write that block.

```bash
python3 scripts/sync_omniroute_models.py                 # probe effort ladders, rewrite models.yml
python3 scripts/sync_omniroute_models.py --no-probe      # reuse config/omniroute-efforts.yml (provisioning)
python3 scripts/sync_omniroute_models.py --update-cache   # write measured ladders back to the repo
```

## Things that look right and are not

**`omniroute/auto/claude-opus` does not select Opus.** The `auto/*` ids are
routing *variants*, not model filters: `auto/claude-opus` maps to the `smart`
weight profile (`open-sse/services/autoCombo/builtinCatalog.ts`) and serves
whichever connected model scores best. Only `auto/<family>` for
`glm|minimax|mimo|zai|gemma|llama|gemini` filters by model family
(`autoCombo/modelFamily.ts`); there is no Claude or Codex family channel.

**Provider-scoped ids pin one key.** `omniroute/cc/claude-opus-5` is a single
connection; when it hits its rate limit the request fails instead of moving to
another account holding the same model.

**Advertised effort tiers are not what the upstreams accept.** `capabilities.effort_tiers`
is missing, stale, or wrong for several models, so the ladder is measured per
combo by the sync script and stored in `config/omniroute-efforts.yml`:

| combo | accepts | rejects |
| --- | --- | --- |
| `glm-5.3` | low, high, max | medium, xhigh (400) |
| `mimo-v2.5-pro` | low, medium, high | minimal, xhigh (400) |
| `deepseek-v4-pro` | low, medium, high, xhigh, max | minimal (400) |
| zed-hosted GPT-5.x | up to xhigh | max, ultra (400 `unknown variant`) |

omp sends `reasoning_effort` on every reasoning model, so a ladder wider than
the upstream's vocabulary turns a level change into a hard 400 mid-session.

**A combo member must exist in the router's live catalog** (`GET /v1/models`),
not just in the registry (`GET /api/models`). A member that is only in the
registry yields `poolSize: 0` and `Combo has no executable targets`, even though
the same id works when requested directly.

## Router-side defects found and fixed 2026-09-17

1. **Phantom manual model.** The claude connection carried a hand-added model
   `cc/claude-fable-5-1` (`GET /api/provider-models?provider=claude`,
   `source: manual`). Its id embedded the `cc/` alias, so upstream received
   `cc/claude-fable-5-1` and answered `404 model: cc/claude-fable-5-1` for every
   request routed to it — including omp sessions whose `slow`/`plan` roles
   pointed at it. Deleted. Claude Fable 5.1 is not in the Claude Code catalog at
   all; the only connection offering `claude-fable-5.1` is the `github` Copilot
   one.
2. **Hidden models.** Every claude model except `claude-opus-5` was marked
   `isHidden`, which is why `cc/claude-sonnet-5` and `cc/claude-fable-5` failed
   with "not available in the active live catalog". `claude-fable-5` and
   `claude-sonnet-5` were unhidden; the older Opus/Sonnet/Haiku revisions stay
   hidden on purpose.
3. **`system` was rewritten to `developer`.** The chat→Responses translator
   turns system turns into `role: "developer"` input items
   (`open-sse/translator/request/openai-responses/toResponses.ts:110-127`), and
   `cloud.zed.dev/completions` accepts only user/assistant/system/tool. Every
   agent request carries a system prompt, so all five GPT-5.x families failed
   with `400 ... unknown variant developer` whenever they fell to the Zed key.
   Patched to emit `system` (the Responses API accepts it; Codex's own executor
   keeps its cache-motivated conversion) with
   `maintenance/omniroute-system-role-patch.sh`. The edit lives in the
   container's writable layer: it survives `docker restart` but not an image
   update, so re-run the script after `docker pull` and verify with
   `maintenance/omniroute-system-role-patch.sh omniroute --check`.
4. **cloudflare-ai catalog names do not route.** The live catalog advertises
   `cf/<vendor>/<model>` ids that the connection rejects ("not available in the
   active live catalog"), while the ids that do work (`cf/@cf/<vendor>/<model>`)
   are hidden from the catalog and therefore cannot be combo members. Cloudflare
   is excluded from the combo set for now.

## Connections that "turn themselves off"

A connection is skipped before dispatch when `test_status` is `banned` or
`unavailable`, or while `rate_limited_until` is in the future — independently of
`is_active`. Nothing clears `banned` automatically, so one upstream 403 takes an
account out of rotation until someone resets it:

```bash
curl -X PATCH -b cookies "$OMNIROUTE_DASHBOARD/api/providers/<id>" \
  -H 'Content-Type: application/json' \
  -d '{"isActive":true,"testStatus":"active","errorCode":null,"lastError":null}'
```

### Root cause: a stale pinned Claude Code version

The native `claude` provider presents a captured claude-cli identity (user
agent, `x-anthropic-billing-header`, `x-app` version — see
`open-sse/executors/claudeIdentity.ts` and
`src/shared/constants/claudeCodeClient.ts`). Anthropic answers a stale identity
with `403 Request not allowed`, and OmniRoute reads a 403 as a permanent ban, so
the account silently leaves rotation. On 2026-09-17 the image pinned
**2.1.220** while the host CLI was **2.1.274**; both Claude Max accounts were
banned within the hour, and requests through omp's own Anthropic credential kept
working, which is what proves the account was fine and the router's request shape
was not. Bumping the pin restored both accounts immediately — `opus-5` served
three consecutive probes with neither connection re-banning.

Keep the pin in step with the installed CLI:

```bash
maintenance/omniroute-claude-client-version.sh omniroute --check   # compare pin vs host CLI
maintenance/omniroute-claude-client-version.sh omniroute           # bump to the host CLI, restart
```

Like the system-role patch, the edit lives in the container's writable layer:
re-run it after `docker pull` and after Claude Code updates on the host.

### Clearing a ban

Nothing clears `banned` automatically:

```bash
curl -X PATCH -b cookies "$OMNIROUTE_DASHBOARD/api/providers/<id>" \
  -H 'Content-Type: application/json' \
  -d '{"isActive":true,"testStatus":"active","errorCode":null,"lastError":null}'
```

Global auto-disable (`GET /api/settings/auto-disable-accounts`) reports
`enabled: false, threshold: 3, scope: all`; even with it off, `test_status:
banned` alone keeps a connection out of the dispatch pool. Also do not "test" a
disabled connection through `POST /api/providers/{id}/test`: it activates the
connection as a side effect.
