#!/usr/bin/env python3
"""Rewrite the `omniroute` provider block in omp's models.yml from the live router.

OmniRoute is the single source of truth. Every model option omp sees is an
OmniRoute *combo* (`GET /v1/combos`): one entry per model family, fanned across
every provider/account serving that family, with router-side failover. Provider-
scoped ids (`cc/...`, `cx/...`, `zed-hosted/...`) are deliberately not exported —
they pin one upstream and drift whenever accounts rotate.

Two things cannot be read from router metadata and are therefore measured:

* accepted `reasoning_effort` words differ per upstream family and the advertised
  `capabilities.effort_tiers` are wrong for several of them (`glm-5.3` advertises
  none and accepts only low/high/max; MiMo rejects xhigh). omp must declare the
  exact set or level changes 400 mid-session, so each level is probed once with a
  throwaway request.
* a combo whose members are all rate-limited cannot be probed at all; its ladder
  is then carried over from the existing models.yml rather than downgraded.
"""

import argparse
import concurrent.futures as futures
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent

# omp's effort ladder, low to high (packages/coding-agent model-resolver).
OMP_EFFORTS = ("low", "medium", "high", "xhigh", "max")
# Reasoning upstreams spend the budget on thinking; too small a cap fails the
# router's own output validation and says nothing about the effort word.
PROBE_BODY = {"messages": [{"role": "user", "content": "hi"}], "max_tokens": 600}
ENV_FILES = (Path.home() / "super.env", Path.home() / "Dev" / "super.env")
# Signals that say nothing about the effort word: the target could not answer.
UNMEASURABLE = re.compile(
    r"\b429\b|rate limit|quota|all targets were skipped|no executable|timed out|timeout", re.I
)
# Only a parameter complaint proves the level is unsupported. Any other failure
# (output validation, stream hiccup) means the upstream accepted the word.
EFFORT_REJECTED = re.compile(
    r"reasoning_effort|invalid request parameters|unknown variant|expected one of"
    r"|effort.*(not|un)suppor",
    re.I,
)


def load_env_file_value(key):
    for path in ENV_FILES:
        if not path.is_file():
            continue
        for line in path.read_text().splitlines():
            name, _, value = line.partition("=")
            if name.strip() == key and value.strip():
                return value.strip()
    return None


def resolve(key, override=None):
    return override or os.environ.get(key) or load_env_file_value(key)


class Router:
    def __init__(self, base_url, api_key, timeout=120):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout

    def _request(self, path, body=None):
        url = f"{self.base_url}{path}"
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Authorization": f"Bearer {self.api_key}"}
        if data:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            try:
                return json.loads(error.read())
            except ValueError:
                return {"error": {"message": f"HTTP {error.code}"}}
        except (TimeoutError, OSError) as error:
            # A stalled upstream (deep thinking, dead key) says nothing about the
            # effort word, so report it as unmeasurable rather than crashing.
            return {"error": {"message": f"request timed out: {error}"}}

    def combos(self):
        return self._request("/v1/combos").get("data", [])

    def catalog(self):
        return {m["id"]: m for m in self._request("/v1/models?prefix=alias").get("data", [])}

    def probe(self, model, effort=None):
        """Classify one request as `accepted`, `rejected`, or `unreachable`."""
        body = dict(PROBE_BODY, model=model)
        if effort:
            body["reasoning_effort"] = effort
        payload = self._request("/v1/chat/completions", body)
        error = payload.get("error")
        if not error:
            return "accepted"
        message = (error.get("message") if isinstance(error, dict) else str(error)) or ""
        if EFFORT_REJECTED.search(message):
            return "rejected"
        if UNMEASURABLE.search(message):
            return "unreachable"
        return "accepted"


def previous_efforts(models_yml):
    """Effort ladders already recorded for omniroute, keyed by model id."""
    if not models_yml.is_file():
        return {}
    document = yaml.safe_load(models_yml.read_text()) or {}
    provider = (document.get("providers") or {}).get("omniroute") or {}
    ladders = {}
    for model in provider.get("models") or []:
        efforts = (model.get("thinking") or {}).get("efforts")
        if model.get("id") and efforts:
            ladders[model["id"]] = list(efforts)
    return ladders


def load_effort_cache(path):
    """Measured ladders committed to the repo, so a fresh host starts correct."""
    if not path or not path.is_file():
        return {}
    document = yaml.safe_load(path.read_text()) or {}
    return {k: list(v) for k, v in (document.get("efforts") or {}).items() if v}


def load_extras(path):
    """Direct provider ids to expose next to the combos.

    Two cases need one: a model served by a single provider (its connections are
    already pooled by the router, so a combo adds nothing) and a model the combo
    path mishandles.
    """
    if not path or not path.is_file():
        return []
    document = yaml.safe_load(path.read_text()) or {}
    return [entry for entry in (document.get("models") or []) if entry.get("id")]


def save_effort_cache(path, ladders):
    payload = {"efforts": {name: ladders[name] for name in sorted(ladders) if ladders[name]}}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "# Measured `reasoning_effort` words each OmniRoute combo's upstreams accept.\n"
        "# Regenerate with scripts/sync_omniroute_models.py --update-cache; never hand-edit:\n"
        "# the advertised capabilities.effort_tiers disagree with what the upstreams take.\n"
        + yaml.safe_dump(payload, sort_keys=False)
    )


def measure_efforts(router, names, fallbacks, workers=8):
    """Probe which of omp's effort levels each combo accepts, concurrently.

    A combo whose upstreams are all rate-limited cannot be measured; it keeps the
    ladder it already had rather than losing levels to a transient 429.
    """
    with futures.ThreadPoolExecutor(max_workers=workers) as pool:
        baselines = {name: pool.submit(router.probe, name) for name in names}
        reachable, results = [], {}
        for name in names:
            if baselines[name].result() == "unreachable":
                kept = fallbacks.get(name, [])
                results[name] = (kept, f"unreachable, kept {','.join(kept) or 'none'}")
            else:
                reachable.append(name)
        probes = {
            (name, level): pool.submit(router.probe, name, level)
            for name in reachable
            for level in OMP_EFFORTS
        }
    for name in reachable:
        recorded = fallbacks.get(name, [])
        accepted, unknown = [], []
        for level in OMP_EFFORTS:
            outcome = probes[(name, level)].result()
            if outcome == "accepted":
                accepted.append(level)
            elif outcome == "unreachable":
                unknown.append(level)
                if level in recorded:
                    accepted.append(level)
        note = "probed " + (",".join(accepted) or "none accepted")
        if unknown:
            note += f" (unmeasured: {','.join(unknown)})"
        results[name] = (accepted, note)
    return results


def build_model_entry(name, combo, catalog, efforts):
    """Describe a combo by what *every* member can honor.

    A request may land on any member, so limits are the minimum and modalities
    the intersection: a 1M-context sibling must not let omp overfill the 400k one.
    """
    rows = [catalog[m["model"]] for m in combo.get("models") or [] if m.get("model") in catalog]
    rows = rows or [catalog.get(name) or {}]

    def floor(field):
        values = [row.get(field) for row in rows if row.get(field)]
        combo_value = (catalog.get(name) or {}).get(field)
        if combo_value:
            values.append(combo_value)
        return min(values) if values else None

    modalities = set(("text", "image"))
    for row in rows:
        modalities &= set(row.get("input_modalities") or ["text"])
    reasoning = any(
        (row.get("capabilities") or {}).get("reasoning")
        or (row.get("capabilities") or {}).get("thinking")
        for row in rows
    )
    context = floor("context_length") or combo.get("computed_context_length")
    output = floor("max_output_tokens")
    if context and output:
        # A member that advertises more output than context (DeepSeek Flash) would
        # otherwise let omp request a budget the smallest member cannot serve.
        output = min(output, context)
    entry = {
        "id": name,
        "name": combo.get("description") or name,
        "reasoning": bool(reasoning) or bool(efforts),
        "input": [m for m in ("text", "image") if m in modalities] or ["text"],
        "contextWindow": context,
        "maxTokens": output,
    }
    entry = {key: value for key, value in entry.items() if value is not None}
    if efforts:
        entry["thinking"] = {"mode": "effort", "efforts": efforts, "defaultLevel": efforts[-1]}
    else:
        # No level the family accepts: keep reasoning display, never send the field.
        entry["compat"] = {"supportsReasoningEffort": False}
    return entry


def write_models_yml(models_yml, block):
    document = yaml.safe_load(models_yml.read_text()) if models_yml.is_file() else {}
    document = document or {}
    document.setdefault("providers", {})["omniroute"] = block
    models_yml.parent.mkdir(parents=True, exist_ok=True)
    models_yml.write_text(yaml.safe_dump(document, sort_keys=False, width=100, allow_unicode=True))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-url", help="router OpenAI base, default $OMNIROUTE_API")
    parser.add_argument("--api-key", help="endpoint key, default $OMNIROUTE_API_KEY")
    parser.add_argument(
        "--models-yml",
        type=Path,
        default=Path.home() / ".omp" / "agent" / "models.yml",
        help="omp model config to rewrite (default %(default)s)",
    )
    parser.add_argument(
        "--efforts-cache",
        type=Path,
        default=ROOT / "config" / "omniroute-efforts.yml",
        help="measured effort ladders used when a combo cannot be probed",
    )
    parser.add_argument(
        "--extras",
        type=Path,
        default=ROOT / "config" / "omniroute-extras.yml",
        help="direct provider ids to expose alongside the combos",
    )
    parser.add_argument(
        "--no-probe",
        action="store_true",
        help="reuse the recorded effort ladders instead of measuring them",
    )
    parser.add_argument(
        "--update-cache", action="store_true", help="write measured ladders back to the cache"
    )
    parser.add_argument("--dry-run", action="store_true", help="print the block, write nothing")
    args = parser.parse_args(argv)

    base_url = resolve("OMNIROUTE_API", args.base_url)
    api_key = resolve("OMNIROUTE_API_KEY", args.api_key)
    if not base_url or not api_key:
        parser.error("set OMNIROUTE_API and OMNIROUTE_API_KEY (or pass --base-url/--api-key)")

    router = Router(base_url, api_key)
    combos = router.combos()
    if not combos:
        print("router reports no combos: create one per model family first", file=sys.stderr)
        return 1
    catalog = router.catalog()
    by_name = {combo["name"]: combo for combo in combos}
    for direct in load_extras(args.extras):
        # A model served by exactly one provider already spans that provider's
        # accounts, so it needs no combo — and some models only work outside the
        # combo path (see docs/omniroute-models.md).
        by_name.setdefault(direct["id"], {"description": direct.get("name"), "models": []})
    names = sorted(by_name)
    # The committed cache is the reviewed measurement, so it wins; whatever the
    # host already had only fills gaps for combos the cache does not know yet.
    recorded = previous_efforts(args.models_yml) | load_effort_cache(args.efforts_cache)

    if args.no_probe:
        measured = {name: (recorded.get(name, []), "recorded") for name in names}
    else:
        measured = measure_efforts(router, names, recorded)

    models = []
    for name in names:
        efforts, note = measured[name]
        models.append(build_model_entry(name, by_name[name], catalog, efforts))
        print(f"{name:24} {note}", file=sys.stderr, flush=True)

    block = {
        "baseUrl": base_url,
        "api": "openai-completions",
        "apiKey": api_key,
        "models": models,
    }
    if args.dry_run:
        print(
            yaml.safe_dump(
                {"providers": {"omniroute": block}}, sort_keys=False, width=100, allow_unicode=True
            )
        )
        return 0
    write_models_yml(args.models_yml, block)
    print(f"wrote {len(models)} combo models to {args.models_yml}", file=sys.stderr)
    if args.update_cache and not args.no_probe:
        save_effort_cache(args.efforts_cache, {n: e for n, (e, _) in measured.items()})
        print(f"updated {args.efforts_cache}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
