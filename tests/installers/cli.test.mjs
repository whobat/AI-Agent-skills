// Tests for bin/cli.js (the npx installer). Run with: node --test tests/installers/
//
// Hermetic: each test builds a throwaway repo copy (installer + fixture skills) and a
// fake HOME, then spawns the installer with USERPROFILE/HOME overridden. No network,
// no winget/pip, and the real ~/.claude is never touched. Requires Node 18+.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

function frontmatter(name, version) {
  return `---\nname: ${name}\nversion: ${version}\ndescription: test fixture\n---\n# ${name}\n`;
}

function write(base, rel, content) {
  const p = path.join(base, ...rel.split('/'));
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, content);
}

// Build a temp repo (bin/cli.js + fixture skills) and a fake home. Fixture skills:
//   alpha-skill  v1.0.0  — ships config.json (secret) + __pycache__ that must never install
//   beta-skill   v2.0.0  — plain
//   cred-skill   v1.0.0  — authCommand (node script writing ~/.credtest/config.json) + configPath
function mkFixture() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'skills-cli-test-'));
  const repo = path.join(tmp, 'repo');
  const home = path.join(tmp, 'home');
  fs.mkdirSync(path.join(repo, 'bin'), { recursive: true });
  fs.mkdirSync(home, { recursive: true });
  fs.copyFileSync(path.join(REPO, 'bin', 'cli.js'), path.join(repo, 'bin', 'cli.js'));
  const skills = path.join(repo, 'skills');
  write(skills, 'alpha-skill/SKILL.md', frontmatter('alpha-skill', '1.0.0'));
  write(skills, 'alpha-skill/config.json', '{"token":"SECRET"}');
  write(skills, 'alpha-skill/config.example.json', '{"token":""}');
  write(skills, 'alpha-skill/scripts/__pycache__/junk.bin', 'x');
  write(skills, 'beta-skill/SKILL.md', frontmatter('beta-skill', '2.0.0'));
  write(skills, 'cred-skill/SKILL.md', frontmatter('cred-skill', '1.0.0'));
  write(skills, 'cred-skill/skill.install.json', JSON.stringify({
    authCommand: 'node write-config.js',
    configPath: '~/.credtest/config.json',
    authHelp: ['Get your token at https://example.test'],
  }, null, 2));
  write(skills, 'cred-skill/write-config.js', [
    "const fs = require('fs'), os = require('os'), path = require('path');",
    "const dir = path.join(os.homedir(), '.credtest');",
    'fs.mkdirSync(dir, { recursive: true });',
    `fs.writeFileSync(path.join(dir, 'config.json'), '{"token":"new"}');`,
  ].join('\n'));
  // tool-skill: warnOnly requirement detected via file paths (not auto-installable, e.g. finsql.exe)
  const toolPath = path.join(tmp, 'fake-tool.exe');
  write(skills, 'tool-skill/SKILL.md', frontmatter('tool-skill', '1.0.0'));
  write(skills, 'tool-skill/skill.install.json', JSON.stringify({
    requirements: [{
      name: 'Fake Tool',
      detectPaths: [toolPath],
      warnOnly: true,
      help: 'Install Fake Tool manually.',
      url: 'https://example.test/tool',
    }],
  }, null, 2));
  return { tmp, repo, home, toolPath };
}

function run(fx, args, input) {
  return spawnSync(process.execPath, [path.join(fx.repo, 'bin', 'cli.js'), ...args], {
    env: { ...process.env, USERPROFILE: fx.home, HOME: fx.home },
    input: input ?? '',
    encoding: 'utf8',
  });
}

const agentDir = (fx) => path.join(fx.home, '.claude', 'skills');
const credConfig = (fx) => path.join(fx.home, '.credtest', 'config.json');

test('--list prints the available skills with repo versions', () => {
  const fx = mkFixture();
  const r = run(fx, ['--list']);
  assert.equal(r.status, 0);
  for (const s of ['alpha-skill', 'beta-skill', 'cred-skill']) assert.match(r.stdout, new RegExp(s));
  assert.match(r.stdout, /beta-skill\s+\[v2\.0\.0\]/);
});

test('--list --agent shows installed vs latest per skill', () => {
  const fx = mkFixture();
  write(agentDir(fx), 'alpha-skill/SKILL.md', frontmatter('alpha-skill', '0.9.0'));
  write(agentDir(fx), 'beta-skill/SKILL.md', frontmatter('beta-skill', '2.0.0'));
  const r = run(fx, ['--list', '--agent', 'claude']);
  assert.match(r.stdout, /alpha-skill\s+\[installed 0\.9\.0 -> latest 1\.0\.0\]/);
  assert.match(r.stdout, /beta-skill\s+\[installed 2\.0\.0, up to date\]/);
  assert.match(r.stdout, /cred-skill\s+\[v1\.0\.0, not installed\]/);
});

test('installs a single skill into the agent dir, showing (new, version)', () => {
  const fx = mkFixture();
  const r = run(fx, ['--agent', 'claude', '--skill', 'beta-skill', '--yes']);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /copied {2}beta-skill -> .+ \(new, 2\.0\.0\)/);
  assert.ok(fs.existsSync(path.join(agentDir(fx), 'beta-skill', 'SKILL.md')));
  assert.ok(!fs.existsSync(path.join(agentDir(fx), 'alpha-skill')));
});

test('reinstalling over an older version shows the transition on the install line', () => {
  const fx = mkFixture();
  write(agentDir(fx), 'beta-skill/SKILL.md', frontmatter('beta-skill', '1.5.0'));
  const r = run(fx, ['--agent', 'claude', '--skill', 'beta-skill', '--yes']);
  assert.match(r.stdout, /copied {2}beta-skill -> .+ \(1\.5\.0 -> 2\.0\.0\)/);
});

test('never installs secrets or caches; keeps config.example.json', () => {
  const fx = mkFixture();
  run(fx, ['--agent', 'claude', '--skill', 'alpha-skill', '--yes']);
  const dest = path.join(agentDir(fx), 'alpha-skill');
  assert.ok(!fs.existsSync(path.join(dest, 'config.json')), 'config.json must be stripped');
  assert.ok(fs.existsSync(path.join(dest, 'config.example.json')));
  assert.ok(!fs.existsSync(path.join(dest, 'scripts', '__pycache__')), '__pycache__ must be stripped');
});

test('--skill all installs every skill', () => {
  const fx = mkFixture();
  const r = run(fx, ['--agent', 'claude', '--skill', 'all', '--yes']);
  assert.equal(r.status, 0, r.stderr);
  for (const s of ['alpha-skill', 'beta-skill', 'cred-skill'])
    assert.ok(fs.existsSync(path.join(agentDir(fx), s, 'SKILL.md')), s);
});

test('fails on unknown skill and unknown agent', () => {
  const fx = mkFixture();
  assert.notEqual(run(fx, ['--agent', 'claude', '--skill', 'nope', '--yes']).status, 0);
  assert.notEqual(run(fx, ['--agent', 'nope', '--skill', 'all', '--yes']).status, 0);
});

test('updates an outdated installed skill, preserving its config.json', () => {
  const fx = mkFixture();
  // Pre-install alpha-skill v0.9.0 with a user config inside the skill dir
  write(agentDir(fx), 'alpha-skill/SKILL.md', frontmatter('alpha-skill', '0.9.0'));
  write(agentDir(fx), 'alpha-skill/config.json', '{"keep":"me"}');
  const r = run(fx, ['--agent', 'claude', '--skill', 'beta-skill', '--yes']);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /alpha-skill: 0\.9\.0 -> 1\.0\.0/);
  const installedMd = fs.readFileSync(path.join(agentDir(fx), 'alpha-skill', 'SKILL.md'), 'utf8');
  assert.match(installedMd, /version: 1\.0\.0/);
  assert.equal(fs.readFileSync(path.join(agentDir(fx), 'alpha-skill', 'config.json'), 'utf8'), '{"keep":"me"}');
});

test('unconfigured: prints credential setup help', () => {
  const fx = mkFixture();
  const r = run(fx, ['--agent', 'claude', '--skill', 'cred-skill', '--yes']);
  assert.match(r.stdout, /Credential setup for "cred-skill"/);
  assert.match(r.stdout, /example\.test/);
});

test('unconfigured + interactive "n": auth not run', () => {
  const fx = mkFixture();
  const r = run(fx, ['--agent', 'claude', '--skill', 'cred-skill'], 'n\n');
  assert.equal(r.status, 0, r.stderr);
  assert.ok(!fs.existsSync(credConfig(fx)), 'auth must not have run');
});

test('unconfigured + interactive "y": auth runs and writes the config', () => {
  const fx = mkFixture();
  const r = run(fx, ['--agent', 'claude', '--skill', 'cred-skill'], 'y\n');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(JSON.parse(fs.readFileSync(credConfig(fx), 'utf8')).token, 'new');
});

test('unconfigured + --auth: runs without prompting', () => {
  const fx = mkFixture();
  const r = run(fx, ['--agent', 'claude', '--skill', 'cred-skill', '--auth', '--yes']);
  assert.equal(r.status, 0, r.stderr);
  assert.ok(fs.existsSync(credConfig(fx)));
});

test('configured + --yes: skips auth and leaves the config untouched', () => {
  const fx = mkFixture();
  write(fx.home, '.credtest/config.json', '{"token":"old"}');
  const r = run(fx, ['--agent', 'claude', '--skill', 'cred-skill', '--yes']);
  assert.match(r.stdout, /already configured/);
  assert.match(r.stdout, /skipping auth/);
  assert.equal(JSON.parse(fs.readFileSync(credConfig(fx), 'utf8')).token, 'old');
});

test('configured + interactive "n": keeps existing credentials', () => {
  const fx = mkFixture();
  write(fx.home, '.credtest/config.json', '{"token":"old"}');
  const r = run(fx, ['--agent', 'claude', '--skill', 'cred-skill'], 'n\n');
  assert.match(r.stdout, /Update tokens\?/);
  assert.match(r.stdout, /keeping existing credentials/);
  assert.equal(JSON.parse(fs.readFileSync(credConfig(fx), 'utf8')).token, 'old');
});

test('configured + interactive "y": updates the tokens', () => {
  const fx = mkFixture();
  write(fx.home, '.credtest/config.json', '{"token":"old"}');
  const r = run(fx, ['--agent', 'claude', '--skill', 'cred-skill'], 'y\n');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(JSON.parse(fs.readFileSync(credConfig(fx), 'utf8')).token, 'new');
});

test('configured: help collapses to a one-line "already configured" message', () => {
  const fx = mkFixture();
  write(fx.home, '.credtest/config.json', '{"token":"old"}');
  const r = run(fx, ['--agent', 'claude', '--skill', 'cred-skill', '--yes']);
  assert.match(r.stdout, /Credentials for "cred-skill": already configured/);
  assert.doesNotMatch(r.stdout, /example\.test/, 'token help must not be dumped when configured');
});

test('warnOnly requirement missing: warns with paths/help but install succeeds', () => {
  const fx = mkFixture();
  const r = run(fx, ['--agent', 'claude', '--skill', 'tool-skill', '--yes']);
  assert.equal(r.status, 0, r.stderr);
  const out = r.stdout + r.stderr;
  assert.match(out, /WARNING: Fake Tool not found/);
  assert.match(out, /fake-tool\.exe/);
  assert.match(out, /Install Fake Tool manually/);
  assert.ok(fs.existsSync(path.join(agentDir(fx), 'tool-skill', 'SKILL.md')), 'skill must still install');
});

test('warnOnly requirement present via detectPaths: reports OK, no warning', () => {
  const fx = mkFixture();
  fs.writeFileSync(fx.toolPath, 'x');
  const r = run(fx, ['--agent', 'claude', '--skill', 'tool-skill', '--yes']);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /requirement OK: Fake Tool/);
  assert.doesNotMatch(r.stdout + r.stderr, /WARNING: Fake Tool/);
});

test('--agent all installs into every agent skills dir', () => {
  const fx = mkFixture();
  const r = run(fx, ['--agent', 'all', '--skill', 'beta-skill', '--yes']);
  assert.equal(r.status, 0, r.stderr);
  for (const dir of [
    path.join(fx.home, '.claude', 'skills'),
    path.join(fx.home, '.agents', 'skills'),
    path.join(fx.home, '.config', 'opencode', 'skills'),
  ]) {
    assert.ok(fs.existsSync(path.join(dir, 'beta-skill', 'SKILL.md')), dir);
  }
});

test('--symlink links instead of copying', () => {
  const fx = mkFixture();
  const r = run(fx, ['--agent', 'claude', '--skill', 'beta-skill', '--symlink', '--yes']);
  assert.equal(r.status, 0, r.stderr);
  const dest = path.join(agentDir(fx), 'beta-skill');
  assert.ok(fs.existsSync(path.join(dest, 'SKILL.md')));
  assert.equal(
    fs.realpathSync(dest),
    fs.realpathSync(path.join(fx.repo, 'skills', 'beta-skill')),
    'dest must resolve to the repo source'
  );
});
