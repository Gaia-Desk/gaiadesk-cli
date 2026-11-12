#!/usr/bin/env node
// Generate the public command reference (docs/commands.md) from a built
// gaiadesk-cli's own help, so the docs never drift from the binary.
//
//   node --experimental-strip-types scripts/gen-cli-docs.mts <path/to/gaiadesk-cli> [<out-dir>]
//   node --experimental-strip-types scripts/gen-cli-docs.mts --check <path/to/gaiadesk-cli> [<out-dir>]
//
// Writes <out-dir>/docs/commands.md (default out-dir: the current directory).
// Run once per release with that release's binary. --check writes nothing: it
// exits 1 when <out-dir>/docs/commands.md is not exactly what that binary
// generates, naming the flags documented but not in the release and the
// release's flags not documented (CI runs it against the latest release).
//
// What it runs (cli_args.rs): `--version`, `--help` (the overview, whose
// "commands:" block lists every command), then `help <command>` for each one,
// falling back to `<command> --help` (login/logout answer only the latter), and
// the `help json` topic. Nothing here dials a desk.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

/** Runs the CLI with `args`; the exit status and stdout. */
export type Runner = (args: string[]) => { status: number | null; stdout: string };

/** Commands the overview does not list but the CLI answers `--help` for. */
export const EXTRA_COMMANDS = ['login', 'logout'];

export function runnerFor(cli: string): Runner {
  return (args) => {
    const r = spawnSync(cli, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 15_000,
      env: { ...process.env, NO_COLOR: '1', TERM: 'dumb' },
    });
    if (r.error) throw new Error(`could not run ${cli}: ${r.error.message}`);
    return { status: r.status, stdout: r.stdout ?? '' };
  };
}

export interface CommandEntry {
  name: string;
  summary: string;
}

/** The overview's `commands:` block: one `  name   summary` row each. */
export function parseOverview(text: string): CommandEntry[] {
  const lines = text.split('\n');
  const start = lines.findIndex((l) => /^commands:\s*$/.test(l));
  if (start < 0) throw new Error('the overview has no "commands:" block (is this gaiadesk-cli --help?)');
  const out: CommandEntry[] = [];
  for (const l of lines.slice(start + 1)) {
    if (l.trim() === '') break;
    const m = /^ {2}([a-z][a-z0-9-]*(?: [a-z][a-z0-9-]*)?)\s{2,}(\S.*)$/.exec(l);
    if (m) out.push({ name: m[1], summary: m[2].trim() });
  }
  if (out.length === 0) throw new Error('the overview\'s "commands:" block is empty');
  return out;
}

/** The help for one command: `help <cmd>`, else `<cmd> --help`. `null`: neither answered. */
export function helpFor(run: Runner, name: string): string | null {
  const words = name.split(' ');
  for (const args of [['help', ...words], [...words, '--help']]) {
    const r = run(args);
    if (r.status === 0 && r.stdout.trim() !== '') return r.stdout.replace(/\s+$/, '');
  }
  return null;
}

const USAGE_INDENT = 'usage: '.length;

export interface ParsedHelp {
  /** From `gaiadesk-cli <name> — <summary>`. */
  summary: string | null;
  usage: string[];
  /** The rest, as blank-line separated blocks. */
  blocks: string[][];
}

export function parseHelp(text: string): ParsedHelp {
  const lines = text.replace(/\r/g, '').split('\n');
  let summary: string | null = null;
  const m = /^gaiadesk-cli [^—]*?— (.+)$/.exec(lines[0] ?? '');
  if (m) {
    summary = m[1].trim();
    lines.shift();
  }
  const blocks: string[][] = [];
  let cur: string[] = [];
  for (const l of lines) {
    if (l.trim() === '') {
      if (cur.length) blocks.push(cur);
      cur = [];
    } else cur.push(l.replace(/\s+$/, ''));
  }
  if (cur.length) blocks.push(cur);
  let usage: string[] = [];
  const ui = blocks.findIndex((b) => /^usage:/.test(b[0]));
  if (ui >= 0) {
    // Continuation lines are indented to sit under the first one, after `usage: `.
    usage = blocks[ui].map((l, i) => (i === 0 ? l.replace(/^usage:\s*/, '') : l.slice(Math.min(USAGE_INDENT, /^ */.exec(l)![0].length))));
    blocks.splice(ui, 1);
  } else if (blocks.length && blocks[0].every((l) => l.startsWith('gaiadesk-cli '))) {
    // login/logout: the usage lines ARE the help's first block.
    usage = blocks.shift()!;
  }
  return { summary, usage, blocks };
}

/** Subcommand words from the usage lines (`token create`, `mesh ip`). */
export function subcommands(name: string, usage: string[]): string[] {
  const out: string[] = [];
  const re = new RegExp(`^gaiadesk-cli ${name.replace(/[-]/g, '\\-')} ([a-z][a-z-]*)\\b`);
  for (const u of usage) {
    const m = re.exec(u.trim());
    if (m && !out.includes(m[1])) out.push(m[1]);
  }
  return out;
}

/** Escape Markdown outside `code spans`: HTML-looking `<x>`, emphasis `*`, and (in tables) `|`. */
export function escapeMd(s: string, table = false): string {
  return s
    .split(/(`[^`]*`)/)
    .map((part, i) => {
      if (i % 2 === 1) return table ? part.replace(/\|/g, '\\|') : part;
      let p = part.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\*/g, '\\*');
      if (table) p = p.replace(/\|/g, '\\|');
      return p;
    })
    .join('');
}

export interface FlagRow {
  flag: string;
  description: string;
}

/** An `options:` block as rows, or `null` when it is not a clean flag table. */
export function parseFlags(block: string[]): FlagRow[] | null {
  if (!/^\s*options:\s*$/.test(block[0] ?? '')) return null;
  const body = block.slice(1);
  if (body.length === 0) return null;
  const indent = /^ */.exec(body[0])![0].length;
  if (indent === 0) return null;
  const rows: FlagRow[] = [];
  for (const l of body) {
    const ind = /^ */.exec(l)![0].length;
    const m = /^(-\S.*?)(?:\s{2,}(\S.*))?$/.exec(l.trim());
    if (ind === indent && m) {
      rows.push({ flag: m[1], description: (m[2] ?? '').trim() });
    } else if (ind > indent && rows.length) {
      const last = rows[rows.length - 1];
      last.description = `${last.description} ${l.trim()}`.trim();
    } else {
      return null;
    }
  }
  return rows;
}

/** A block whose lines are aligned in columns (two spaces inside a line, or a ragged indent). */
function isAligned(block: string[]): boolean {
  if (block.some((l) => /\S {2,}\S/.test(l))) return true;
  const indents = new Set(block.map((l) => /^ */.exec(l)![0].length));
  return indents.size > 1;
}

function fence(lang: string, lines: string[]): string {
  return ['```' + lang, ...lines, '```'].join('\n');
}

function dedent(lines: string[]): string[] {
  const n = Math.min(...lines.filter((l) => l.trim()).map((l) => /^ */.exec(l)![0].length));
  return lines.map((l) => l.slice(n));
}

/** One block of help prose, as Markdown. */
export function renderBlock(block: string[]): string {
  const head = /^\s*(options|examples):\s*(.*)$/i.exec(block[0]);
  if (head && head[1].toLowerCase() === 'options' && head[2] === '') {
    const rows = parseFlags(block);
    if (rows) {
      const table = ['| Flag | Description |', '| --- | --- |'];
      for (const r of rows) table.push(`| ${'`' + r.flag.replace(/\|/g, '\\|') + '`'} | ${escapeMd(r.description, true)} |`);
      return `**Options**\n\n${table.join('\n')}`;
    }
  }
  if (head && head[1].toLowerCase() === 'examples' && head[2] === '') {
    const ex = dedent(block.slice(1)).map((l) => l.replace(/^(gaiadesk-cli .*?)\s{2,}\((.*)\)$/, '$1   # $2'));
    return `**Examples**\n\n${fence('sh', ex)}`;
  }
  if (isAligned(block) || head) return fence('text', dedent(block));
  return escapeMd(block.map((l) => l.trim()).join('\n'));
}

/** `the desks you can reach.` → `The desks you can reach.` */
export function sentence(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

/** A section's one-line summary: its title's, else the first usage line's trailing words, else the overview's. */
export function summaryOf(p: ParsedHelp, fallback: string): string {
  if (p.summary) return p.summary;
  const tail = /\S\s{2,}([a-z].*)$/.exec(p.usage[0] ?? '');
  return tail ? tail[1].trim() : fallback;
}

/** Desk ids that are documented placeholders; any other 9-digit id in the help is replaced by the first. */
export const PLACEHOLDER_IDS = ['123456789', '234567890'];

/** Public docs never carry a real desk id: every other 9-digit number becomes 123456789. */
export function scrubDeskIds(text: string, found: Set<string> = new Set()): string {
  return text.replace(/(?<![\d.])\d{9}(?![\d.])/g, (id) => {
    if (PLACEHOLDER_IDS.includes(id)) return id;
    found.add(id);
    return PLACEHOLDER_IDS[0];
  });
}

export function slug(heading: string): string {
  return heading
    .toLowerCase()
    .replace(/[^a-z0-9 -]/g, '')
    .trim()
    .replace(/ /g, '-');
}

export interface Section {
  heading: string;
  summary: string;
  help: string;
}

export function renderSection(s: Section, names: string[]): string {
  const p = parseHelp(s.help);
  const summary = summaryOf(p, s.summary);
  const out: string[] = [`## ${s.heading}`];
  if (summary) out.push('', escapeMd(sentence(summary)));
  if (p.usage.length) out.push('', '**Usage**', '', fence('text', p.usage));
  const subs = names.length === 1 ? subcommands(names[0], p.usage) : [];
  if (subs.length) out.push('', `**Subcommands:** ${subs.map((x) => '`' + x + '`').join(', ')}`);
  for (const b of p.blocks) out.push('', renderBlock(b));
  if (/--json\b/.test(s.help)) {
    out.push(
      '',
      '> **JSON:** with `--json` this command prints one JSON document on stdout (or the error envelope ' +
        '`{"error":{"kind","message"}}` on failure). The exact shape is defined in the JSON Schema printed by ' +
        '`gaiadesk-cli schema --json`; see also [JSON output](#json-output).',
    );
  }
  return out.join('\n');
}

export interface Docs {
  version: string;
  /** Desk ids the help carried that were replaced by a placeholder. */
  scrubbed: string[];
  markdown: string;
}

/** Everything: the overview, one section per command, the JSON topic. */
export function generate(raw: Runner): Docs {
  const scrubbed = new Set<string>();
  const run: Runner = (args) => {
    const r = raw(args);
    return { status: r.status, stdout: scrubDeskIds(r.stdout, scrubbed) };
  };
  const ver = run(['--version']);
  const version = /gaiadesk-cli\s+(\S+)/.exec(ver.stdout)?.[1] ?? 'unknown';
  const overview = run(['--help']);
  if (overview.status !== 0) throw new Error('gaiadesk-cli --help failed');
  const commands = parseOverview(overview.stdout);

  // Sections: listed commands, then the extras, merging ones whose help is identical (login/logout).
  const sections: { names: string[]; summary: string; help: string }[] = [];
  const add = (name: string, summary: string, help: string) => {
    const same = sections.find((s) => s.help === help);
    if (same) same.names.push(name);
    else sections.push({ names: [name], summary, help });
  };
  for (const c of commands) {
    const help = helpFor(run, c.name);
    if (help === null) throw new Error(`no help for \`${c.name}\` (tried \`help ${c.name}\` and \`${c.name} --help\`)`);
    add(c.name, c.summary, help);
  }
  for (const name of EXTRA_COMMANDS) {
    const help = helpFor(run, name);
    if (help !== null) add(name, '', help);
  }

  const ov = parseHelp(overview.stdout.replace(/\s+$/, ''));
  const ovBlocks = ov.blocks.filter((b) => !/^commands:/.test(b[0]));
  const json = helpFor(run, 'json');

  const md: string[] = [
    '# gaiadesk-cli command reference',
    '',
    `<!-- Generated by scripts/gen-cli-docs.mts from gaiadesk-cli ${version}'s own help. Do not edit by hand. -->`,
    '',
    `Generated from \`gaiadesk-cli ${version}\`. Every command also prints this with \`gaiadesk-cli <command> --help\` ` +
      '(or `gaiadesk-cli help <command>`).',
    '',
    '## Contents',
    '',
    '- [Overview](#overview)',
  ];
  for (const s of sections) {
    const heading = s.names.join(', ');
    const summary = summaryOf(parseHelp(s.help), s.summary);
    md.push(`- [\`${heading}\`](#${slug(heading)})${summary ? ` — ${escapeMd(summary)}` : ''}`);
  }
  if (json) md.push('- [JSON output](#json-output)');
  md.push('', '## Overview', '');
  if (ov.summary) md.push(escapeMd(sentence(ov.summary)), '');
  if (ov.usage.length) md.push(fence('text', ov.usage), '');
  for (const b of ovBlocks) md.push(renderBlock(b), '');
  for (const s of sections) {
    md.push(renderSection({ heading: s.names.join(', '), summary: s.summary, help: s.help }, s.names), '');
  }
  if (json) {
    const p = parseHelp(json);
    md.push('## JSON output', '');
    if (p.summary) md.push(escapeMd(sentence(p.summary)), '');
    md.push(fence('text', [...p.blocks.flatMap((b) => [...b, ''])].slice(0, -1)), '');
    md.push(
      'The JSON Schema (draft 2020-12) of every result, error, request and event type is printed by ' +
        '`gaiadesk-cli schema --json`; the SDKs generate their types from it.',
      '',
    );
  }
  return { version, scrubbed: [...scrubbed].sort(), markdown: md.join('\n').replace(/\n{3,}/g, '\n\n').replace(/\s+$/, '') + '\n' };
}

const FLAG = /(?<![\w<-])--[a-z][a-z0-9-]*/g;

/** Each `` `--flag` `` cell of the options tables (with its section), so a flag mentioned only in prose does not count. */
export function flagRows(md: string): Set<string> {
  const out = new Set<string>();
  let section = '';
  for (const l of md.split('\n')) {
    if (l.startsWith('## ')) section = l.slice(3);
    const cell = /^\| `([^`]*)` \|/.exec(l);
    if (cell) for (const f of cell[1].match(FLAG) ?? []) out.add(`${section}: ${f}`);
  }
  return out;
}

/** What differs between the committed reference and the generated one; empty when they are identical. */
export function compareDocs(committed: string, generated: string): string[] {
  if (committed === generated) return [];
  const have = flagRows(committed);
  const want = flagRows(generated);
  const out: string[] = [];
  for (const f of have) if (!want.has(f)) out.push(`documented but not in the release: ${f}`);
  for (const f of want) if (!have.has(f)) out.push(`in the release but not documented: ${f}`);
  const a = committed.split('\n');
  const b = generated.split('\n');
  const first = a.findIndex((l, i) => l !== b[i]);
  const at = first < 0 ? Math.min(a.length, b.length) : first;
  out.push(`first difference at line ${at + 1}:`, `  docs:    ${a[at] ?? '(end of file)'}`, `  release: ${b[at] ?? '(end of file)'}`);
  return out;
}

function main(): void {
  const argv = process.argv.slice(2).filter((a) => a !== '--');
  const check = argv.includes('--check');
  const args = argv.filter((a) => a !== '--check');
  if (args.length < 1 || args.includes('--help') || args.includes('-h')) {
    console.error('usage: node --experimental-strip-types scripts/gen-cli-docs.mts [--check] <path/to/gaiadesk-cli> [<out-dir>]');
    process.exit(args.length < 1 ? 2 : 0);
  }
  const cli = resolve(args[0]);
  const outDir = resolve(args[1] ?? '.');
  const docs = generate(runnerFor(cli));
  const file = join(outDir, 'docs', 'commands.md');
  if (check) {
    const diff = compareDocs(existsSync(file) ? readFileSync(file, 'utf8') : '', docs.markdown);
    if (diff.length === 0) {
      console.log(`${file} matches gaiadesk-cli ${docs.version}`);
      return;
    }
    console.error(`${file} is stale against gaiadesk-cli ${docs.version}:`);
    for (const l of diff) console.error(`  ${l}`);
    console.error(`regenerate it: node --experimental-strip-types scripts/gen-cli-docs.mts <gaiadesk-cli ${docs.version}> .`);
    process.exit(1);
  }
  mkdirSync(join(outDir, 'docs'), { recursive: true });
  writeFileSync(file, docs.markdown);
  console.log(`wrote ${file} (gaiadesk-cli ${docs.version})`);
  if (docs.scrubbed.length) {
    console.error(`note: replaced ${docs.scrubbed.length} non-placeholder desk id(s) in the help with ${PLACEHOLDER_IDS[0]}; ` +
      'use a placeholder in the help text itself');
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  try {
    main();
  } catch (e) {
    console.error((e as Error).message);
    process.exit(1);
  }
}
