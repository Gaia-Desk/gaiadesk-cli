// node --experimental-strip-types --test scripts/gen-cli-docs.test.mts
// gen-cli-docs.mts against a fake gaiadesk-cli (fixtures/gen-cli-docs) that
// prints help in the real layout.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  escapeMd,
  generate,
  helpFor,
  parseFlags,
  parseHelp,
  parseOverview,
  runnerFor,
  scrubDeskIds,
  slug,
  subcommands,
} from './gen-cli-docs.mts';

const here = dirname(fileURLToPath(import.meta.url));
const FAKE = join(here, 'fixtures', 'gen-cli-docs', 'fake-gaiadesk-cli');
const SCRIPT = join(here, 'gen-cli-docs.mts');

test('the overview lists every command, two-word ones included', () => {
  const run = runnerFor(FAKE);
  const cmds = parseOverview(run(['--help']).stdout);
  assert.deepEqual(
    cmds.map((c) => c.name),
    ['exec', 'token', 'agent run'],
  );
  assert.match(cmds[0].summary, /^run one command/);
  assert.throws(() => parseOverview('no commands here'), /commands:/);
});

test('help falls back from `help <cmd>` to `<cmd> --help`', () => {
  const run = runnerFor(FAKE);
  assert.match(helpFor(run, 'exec')!, /^gaiadesk-cli exec —/);
  assert.match(helpFor(run, 'login')!, /^gaiadesk-cli login \[--json\]/);
  assert.match(helpFor(run, 'agent run')!, /^gaiadesk-cli agent run —/);
  assert.equal(helpFor(run, 'nonsense'), null);
});

test('help parses into summary, usage (indent kept) and blocks', () => {
  const run = runnerFor(FAKE);
  const p = parseHelp(helpFor(run, 'token')!);
  assert.equal(p.summary, "scoped, expiring agent tokens, administered by the desk's owner.");
  assert.equal(p.usage[0], 'gaiadesk-cli token create --desk <id> [--name <n>] [--expires 7d]');
  assert.equal(p.usage[1], '                          [--out <file>] [--json]');
  assert.equal(p.usage[2], 'gaiadesk-cli token list --desk <id> [--json]');
  assert.deepEqual(subcommands('token', p.usage), ['create', 'list', 'revoke']);
  assert.deepEqual(subcommands('exec', ['gaiadesk-cli exec --desk-id <id> -- <cmd>']), []);
  const login = parseHelp(helpFor(run, 'login')!);
  assert.equal(login.summary, null);
  assert.equal(login.usage.length, 2);
});

test('options become a table; a ragged options line is not', () => {
  const rows = parseFlags([
    'options:',
    '  --desk-id <id>           the desk (-d)',
    '  --shell <s>              default | sh',
    '                           more about it',
    '  --keep-awake',
  ]);
  assert.deepEqual(rows, [
    { flag: '--desk-id <id>', description: 'the desk (-d)' },
    { flag: '--shell <s>', description: 'default | sh more about it' },
    { flag: '--keep-awake', description: '' },
  ]);
  assert.equal(parseFlags(['options: --model <m>', '         --out-dir <dir>']), null);
  assert.equal(parseFlags(['options:', '  not a flag   at all']), null);
});

test('markdown escaping leaves code spans alone', () => {
  assert.equal(escapeMd('a <dir> and `<dir>`'), 'a &lt;dir&gt; and `<dir>`');
  assert.equal(escapeMd('x | y `a | b`', true), 'x \\| y `a \\| b`');
  assert.equal(escapeMd('gaiadesk_job_*'), 'gaiadesk_job_\\*');
  assert.equal(slug('login, logout'), 'login-logout');
  assert.equal(slug('agent run'), 'agent-run');
});

test('desk ids other than the placeholders are scrubbed', () => {
  const found = new Set<string>();
  assert.equal(scrubDeskIds('-d 123456789 -d 987654321 -d 234567890 v0.10.324 1234567890', found), '-d 123456789 -d 123456789 -d 234567890 v0.10.324 1234567890');
  assert.deepEqual([...found], ['987654321']);
});

test('the whole document: TOC, sections, tables, examples, JSON notes', () => {
  const docs = generate(runnerFor(FAKE));
  const md = docs.markdown;
  assert.equal(docs.version, '9.8.7');
  assert.deepEqual(docs.scrubbed, ['987654321']);
  assert.doesNotMatch(md, /987654321/);
  assert.match(md, /^# gaiadesk-cli command reference\n/);
  assert.match(md, /Generated from `gaiadesk-cli 9\.8\.7`/);
  // TOC, in the overview's order, then login/logout merged, then JSON.
  const toc = md.slice(md.indexOf('## Contents'), md.indexOf('## Overview'));
  assert.deepEqual(
    [...toc.matchAll(/\]\(#([a-z-]+)\)/g)].map((m) => m[1]),
    ['overview', 'exec', 'token', 'agent-run', 'login-logout', 'json-output'],
  );
  assert.match(toc, /\[`login, logout`\]\(#login-logout\) — sign this CLI in/);
  for (const h of ['## exec', '## token', '## agent run', '## login, logout', '## JSON output']) {
    assert.ok(md.includes(`\n${h}\n`), `missing ${h}`);
  }
  assert.match(md, /## exec\n\nRun ONE command on a desk/);
  assert.match(md, /\| `--shell <s>` \| default \\\| sh \\\| pwsh \\\| cmd \\\| none ONE argument after `--` is a command line \(`-- 'ls \\\| wc -l'`\) \|/);
  assert.match(md, /```sh\ngaiadesk-cli exec -d 123456789 -- hostname   # a Windows desk: cmd\.exe\n/);
  assert.match(md, /A &lt;placeholder&gt; outside code is escaped\./);
  assert.match(md, /```text\nexit codes:\n {2}0-255/);
  assert.match(md, /\*\*Subcommands:\*\* `create`, `list`, `revoke`/);
  // agent run's inline options stay preformatted.
  assert.match(md, /```text\noptions: --model <m> --max-steps <n>\n {9}--out-dir <dir>\n```/);
  // Commands that take --json point at the schema.
  const exec = md.slice(md.indexOf('## exec'), md.indexOf('## token'));
  assert.match(exec, /gaiadesk-cli schema --json/);
  const agent = md.slice(md.indexOf('## agent run'), md.indexOf('## login'));
  assert.doesNotMatch(agent, /schema --json/);
  assert.match(md, /## JSON output\n\nThe shapes a program can rely on\./);
  assert.ok(md.endsWith('\n') && !md.endsWith('\n\n'));
  assert.doesNotMatch(md, /\n\n\n/);
});

test('a listed command without help is an error, not a silent gap', () => {
  process.env.FAKE_CLI_BROKEN = '1';
  try {
    assert.throws(() => generate(runnerFor(FAKE)), /no help for `broken`/);
  } finally {
    delete process.env.FAKE_CLI_BROKEN;
  }
});

test('the script writes <out>/docs/commands.md and is deterministic', () => {
  const out = mkdtempSync(join(tmpdir(), 'gen-cli-docs-'));
  try {
    const run = () =>
      spawnSync(process.execPath, ['--experimental-strip-types', SCRIPT, FAKE, out], { encoding: 'utf8' });
    const r1 = run();
    assert.equal(r1.status, 0, r1.stderr);
    assert.match(r1.stderr, /replaced 1 non-placeholder desk id/);
    const first = readFileSync(join(out, 'docs', 'commands.md'), 'utf8');
    assert.equal(run().status, 0);
    assert.equal(readFileSync(join(out, 'docs', 'commands.md'), 'utf8'), first);
    const bad = spawnSync(process.execPath, ['--experimental-strip-types', SCRIPT, join(out, 'missing-cli'), out], { encoding: 'utf8' });
    assert.equal(bad.status, 1);
    assert.match(bad.stderr, /could not run/);
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});

test('--check passes on fresh docs and names a dropped or extra flag', () => {
  const out = mkdtempSync(join(tmpdir(), 'gen-cli-docs-'));
  try {
    const run = (...a: string[]) =>
      spawnSync(process.execPath, ['--experimental-strip-types', SCRIPT, ...a], { encoding: 'utf8' });
    const missing = run('--check', FAKE, out);
    assert.equal(missing.status, 1, 'no docs at all is stale');
    assert.equal(run(FAKE, out).status, 0);
    const ok = run('--check', FAKE, out);
    assert.equal(ok.status, 0, ok.stderr);
    const file = join(out, 'docs', 'commands.md');
    const fresh = readFileSync(file, 'utf8');
    const row = fresh.split('\n').find((l) => /^\| `--/.test(l))!;
    const flag = /`(--[a-z][a-z0-9-]*)/.exec(row)![1];
    writeFileSync(file, fresh.replace(row + '\n', ''));
    const dropped = run('--check', FAKE, out);
    assert.equal(dropped.status, 1);
    assert.match(dropped.stderr, new RegExp(`in the release but not documented: .*${flag}`));
    writeFileSync(file, fresh.replace(row, `${row}\n| \`--made-up\` | not real |`));
    const extra = run('--check', FAKE, out);
    assert.equal(extra.status, 1);
    assert.match(extra.stderr, /documented but not in the release: .*--made-up/);
    writeFileSync(file, fresh.replace('Do not edit by hand.', 'Edited by hand.'));
    assert.equal(run('--check', FAKE, out).status, 1, 'any other edit is stale too');
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});
