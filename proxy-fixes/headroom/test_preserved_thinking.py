"""Run with the installed Headroom Python; no API calls or private fixtures."""

import argparse
import copy
import hashlib
import importlib.metadata
import inspect
import json
import sys
import unittest
from pathlib import Path

from headroom.proxy.body_forwarding import (
    outbound_body_is_client_bytes,
    select_outbound_body,
)


class PreservedThinkingContract(unittest.TestCase):
    def assert_protected(self, original):
        raw = json.dumps(original, indent=2).encode()
        modified = copy.deepcopy(original)
        modified["system"] = "rewritten system"
        modified["tools"] = []
        result = select_outbound_body(
            body=modified,
            original_body_bytes=raw,
            body_mutated=True,
            mutation_reasons=["system_compression"],
        )
        self.assertEqual(result.content, raw)
        self.assertTrue(result.dropped_mutations)
        self.assertTrue(outbound_body_is_client_bytes(body=modified, original_body_bytes=raw))

    def test_first_adaptive_request_is_protected_before_signatures_exist(self):
        self.assert_protected(
            {
                "model": "claude-fable-5-1",
                "system": "original system",
                "thinking": {"type": "adaptive"},
                "messages": [{"role": "user", "content": "synthetic prompt"}],
            }
        )

    def test_first_enabled_request_is_protected(self):
        self.assert_protected(
            {
                "thinking": {"type": "enabled", "budget_tokens": 4096},
                "messages": [{"role": "user", "content": "synthetic prompt"}],
            }
        )

    def test_empty_signed_thinking_protects_its_entire_prefix(self):
        self.assert_protected(
            {
                "system": "original system",
                "messages": [
                    {
                        "role": "assistant",
                        "content": [
                            {
                                "type": "thinking",
                                "thinking": "",
                                "signature": "synthetic-signature",
                            },
                            {"type": "tool_use", "id": "tool_1", "name": "lookup", "input": {}},
                        ],
                    }
                ],
            }
        )

    def test_redacted_thinking_protects_its_entire_prefix(self):
        self.assert_protected(
            {
                "messages": [
                    {
                        "role": "assistant",
                        "content": [
                            {"type": "redacted_thinking", "data": "synthetic-opaque-block"},
                        ],
                    }
                ],
            }
        )

    def test_removed_blocks_cannot_disable_original_body_protection(self):
        original = {
            "messages": [
                {
                    "role": "assistant",
                    "content": [
                        {"type": "thinking", "thinking": "", "signature": "synthetic-signature"},
                    ],
                }
            ]
        }
        raw = json.dumps(original).encode()
        result = select_outbound_body(
            body={"messages": []}, original_body_bytes=raw, body_mutated=True
        )
        self.assertEqual(result.content, raw)

    def test_unprotected_requests_can_still_be_optimized(self):
        raw = b'{"messages":[{"role":"user","content":"original"}]}'
        modified = {"messages": [{"role": "user", "content": "optimized"}]}
        result = select_outbound_body(body=modified, original_body_bytes=raw, body_mutated=True)
        self.assertEqual(json.loads(result.content), modified)
        self.assertFalse(outbound_body_is_client_bytes(body=modified, original_body_bytes=raw))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--manifest", type=Path)
    options, remaining = parser.parse_known_args()
    if options.manifest:
        reviewed = json.loads(options.manifest.read_text())["headroom"]
        if importlib.metadata.version("headroom-ai") != reviewed["version"]:
            raise SystemExit("Unreviewed Headroom version; refusing startup.")
        root = Path(inspect.getfile(select_outbound_body)).parents[2]
        for relative, expected in reviewed["files"].items():
            actual = hashlib.sha256((root / relative).read_bytes()).hexdigest()
            if actual != expected["after"]:
                raise SystemExit(f"Unreviewed Headroom artifact {relative}; refusing startup.")
    unittest.main(argv=[sys.argv[0], *remaining])
