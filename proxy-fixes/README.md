# Preserved-thinking proxy repair

Applies to the inspected Headroom 0.36.3 and pxpipe-proxy 0.13.1 artifacts. This is an optional repair for an existing proxy chain, not a prerequisite for using providers directly.

## Failure and fix

Claude Fable 5.1 binds preserved thinking to the top-level system prompt, tools, and earlier messages. Keeping only the thinking text/signature unchanged is insufficient. The observed pxpipe transform reduced a failing request from 259 messages to 14 while leaving its latest assistant message intact. That still broke the signed prefix.

Two fixes enforce the same boundary:

- pxpipe returns the original request bytes before history rendering, system/tool rewriting, or pin processing.
- Headroom's final forwarding policy no longer permits prefix edits merely because the thinking blocks themselves compare equal.

Protection starts on the first request with enabled/adaptive thinking or block-binding controls, before a signature exists. Requests carrying thinking/redacted-thinking blocks are protected too. Ordinary non-thinking requests remain eligible for compression. Neither fix strips thinking or changes the requested model/effort.

References: [Anthropic preserved-thinking rules](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking), [pxpipe source](https://github.com/teamchong/pxpipe/tree/v0.13.1), [Headroom source](https://github.com/headroomlabs-ai/headroom).

## Install or reapply

`manifest.json` contains before/after SHA-256 values. The installer accepts only the exact reviewed originals or the already-patched outputs. A different package version or locally modified artifact is a refusal, not a guessed patch.

For a new optional proxy installation in predictable user-owned locations:

```bash
uv tool install 'headroom-ai==0.36.3'
npm install --prefix "$HOME/.local/share/code-factory/proxies" --save-exact 'pxpipe-proxy@0.13.1'
python3 proxy-fixes/install.py \
  --headroom-python "$HOME/.local/share/uv/tools/headroom-ai/bin/python" \
  --pxpipe-package "$HOME/.local/share/code-factory/proxies/node_modules/pxpipe-proxy" \
  --node "$(command -v node)"
```

For an existing installation, pass its actual Python and package paths instead. The installer patches and tests software; it does not configure credentials, create proxy services, change routing, or restart services. It installs `ExecStartPre` guards for existing `headroom.service` and `pxpipe.service` units and copies the checks into `~/.local/share/code-factory/proxy-fixes`, independent of this checkout.

When both proxy services have no active request connections, restart pxpipe first, then Headroom:

```bash
systemctl --user restart pxpipe.service
systemctl --user restart headroom.service
systemctl --user is-active pxpipe.service headroom.service
```

Use `--no-guards` only for an isolated container without systemd. Direct CLI launches do not pass through systemd's restart guard; run the checks explicitly after manual package changes.

## Verification

The six pxpipe regression cases cover first-turn adaptive/enabled thinking, empty signed thinking, redacted thinking, HTTP body/header preservation, and the still-compressing non-thinking control. `pxpipe/source.patch` includes the source change and these tests against upstream commit `ffbb0d8df4b0b11f9191605a2f81e054fc072b02`.

The six Headroom cases exercise both outbound-policy entrypoints, original-body protection after block removal, first-turn protection, and an unprotected compression control:

```bash
"$HOME/.local/share/uv/tools/headroom-ai/bin/python" proxy-fixes/headroom/test_preserved_thinking.py
node proxy-fixes/pxpipe/check.mjs "$HOME/.local/share/code-factory/proxies/node_modules/pxpipe-proxy"
```

On the source VPS, these cases failed before the fixes and passed afterward. The saved failing request then remained byte-for-byte unchanged offline. Both restarted listeners were healthy, and an isolated three-turn authenticated Fable conversation returned HTTP 200 with `preserved_thinking_context` passthrough recorded. The live arithmetic responses did not emit signed thinking blocks, so exact opaque-block replay is proven by the offline regressions, not overstated as a live signed-block test.

## Existing histories and updates

Do not blindly retry an identical rejected body. Stop the prefix mutation first. Existing signatures may already be bound to an earlier transformed prefix. Keep the original transcript intact; use the provider's documented binding controls or explicitly start a new context if that history cannot recover. Do not silently delete reasoning or switch signers.

A package update that loses the preservation behavior fails its startup guard. Review the new release and rerun the regression cases before updating the patch manifest. Do not remove the guard simply to get the service started.

Original patched files are saved under `~/.local/state/code-factory/proxy-backups`. Restoring them also restores the bug; rollback should be deliberate and paired with safe routing. No private request bodies, signatures, credentials, or session logs are included here. Upstream licenses/notices accompany the patches.
