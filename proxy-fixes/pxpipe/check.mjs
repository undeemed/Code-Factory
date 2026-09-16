#!/usr/bin/env node
// Offline semantic check; never contacts a provider or reads session history.
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const packageRoot = process.argv[2];
if (!packageRoot) throw new Error('Usage: node check.mjs /path/to/pxpipe-proxy');
const manifestPath = process.argv[3] ?? new URL('../manifest.json', import.meta.url);
const reviewed = JSON.parse(readFileSync(manifestPath, 'utf8')).pxpipe;
const installed = JSON.parse(readFileSync(resolve(packageRoot, 'package.json'), 'utf8'));
if (installed.version !== reviewed.version) throw new Error('Unreviewed pxpipe version; refusing startup.');
for (const [relative, expected] of Object.entries(reviewed.files)) {
  const actual = createHash('sha256').update(readFileSync(resolve(packageRoot, relative))).digest('hex');
  if (actual !== expected.after) throw new Error(`Unreviewed pxpipe artifact ${relative}; refusing startup.`);
}
const { transformAnthropicMessages } = await import(pathToFileURL(resolve(packageRoot, 'dist/core/library.js')));
const system = Array.from({ length: 500 }, (_, i) =>
  `Rule ${i}: Preserve customer_${i} identifiers and return the original record without changing its sequence.`,
).join('\n');
const base = { model: 'claude-fable-5-1', system, messages: [{ role: 'user', content: 'Synthetic check.' }] };
const cases = [
  { ...base, thinking: { type: 'adaptive' } },
  { ...base, thinking: { type: 'enabled', budget_tokens: 4096 } },
  { ...base, messages: [...base.messages, { role: 'assistant', content: [
    { type: 'thinking', thinking: '', signature: 'synthetic-signature' },
  ] }] },
  { ...base, messages: [...base.messages, { role: 'assistant', content: [
    { type: 'redacted_thinking', data: 'synthetic-redacted-block' },
  ] }] },
];
for (const [index, body] of cases.entries()) {
  const original = Buffer.from(JSON.stringify(body, null, 2));
  const result = await transformAnthropicMessages({ body: original, model: body.model, options: { charsPerToken: 1 } });
  if (!Buffer.from(result.body).equals(original) || result.applied) {
    throw new Error(`Unsafe thinking-prefix mutation in case ${index}; refusing proxy startup. Reapply reviewed proxy fix.`);
  }
}
const control = await transformAnthropicMessages({ body: Buffer.from(JSON.stringify(base)), model: base.model, options: { charsPerToken: 1 } });
if (!control.applied) throw new Error('Non-thinking control did not exercise compression; guard check is inconclusive.');
console.log('pxpipe preserved-thinking contract: passed (four protected cases + compression control)');
