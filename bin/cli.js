#!/usr/bin/env node
/*
 * AI-Agent-Skills installer
 *
 *   npx github:whobat/AI-Agent-skills                      # interactive
 *   npx github:whobat/AI-Agent-skills --agent claude --skill all
 *   npx github:whobat/AI-Agent-skills --agent codex --skill tidsregistrering --auth
 *
 * Flags:
 *   --agent <claude|codex|opencode>   target agent (prompted if omitted)
 *   --skill <name|all>                skill to install (prompted if omitted)
 *   --auth                            run a skill's credential setup after install
 *   --symlink                         symlink instead of copy
 *   --list                            list available skills and exit
 *   -y, --yes                         assume yes (non-interactive)
 *   -h, --help                        show help
 */
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const { spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const SKILLS_DIR = path.join(ROOT, 'skills');

const TARGETS = {
  claude: path.join(os.homedir(), '.claude', 'skills'),
  codex: path.join(os.homedir(), '.agents', 'skills'),
  opencode: path.join(os.homedir(), '.config', 'opencode', 'skills'),
};

function parseArgs(argv) {
  const a = { agent: null, skill: null, auth: false, symlink: false, list: false, yes: false, help: false };
  for (let i = 0; i < argv.length; i++) {
    const v = argv[i];
    if (v === '--agent') a.agent = argv[++i];
    else if (v === '--skill') a.skill = argv[++i];
    else if (v === '--auth') a.auth = true;
    else if (v === '--symlink') a.symlink = true;
    else if (v === '--list') a.list = true;
    else if (v === '-y' || v === '--yes') a.yes = true;
    else if (v === '-h' || v === '--help') a.help = true;
  }
  return a;
}

function listSkills() {
  return fs.readdirSync(SKILLS_DIR, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);
}

function ask(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((res) => rl.question(question, (ans) => { rl.close(); res(ans.trim()); }));
}

function pythonCmd() {
  for (const c of ['python', 'python3', 'py']) {
    const r = spawnSync(c, ['--version'], { stdio: 'ignore' });
    if (r.status === 0) return c;
  }
  return null;
}

function installSkill(name, destDir, symlink) {
  const src = path.join(SKILLS_DIR, name);
  const dest = path.join(destDir, name);
  fs.mkdirSync(destDir, { recursive: true });
  fs.rmSync(dest, { recursive: true, force: true });
  if (symlink) {
    fs.symlinkSync(src, dest, 'junction');
    console.log(`  linked  ${name} -> ${dest}`);
  } else {
    fs.cpSync(src, dest, { recursive: true });
    // never install real secrets / caches
    fs.rmSync(path.join(dest, 'config.json'), { force: true });
    rmAll(dest, 'config.json');
    rmAll(dest, '__pycache__');
    console.log(`  copied  ${name} -> ${dest}`);
  }
  return dest;
}

function rmAll(dir, base) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.name === base) fs.rmSync(p, { recursive: true, force: true });
    else if (e.isDirectory()) rmAll(p, base);
  }
}

async function maybeRunAuth(installedDir, autoYes) {
  const manifest = path.join(installedDir, 'skill.install.json');
  if (!fs.existsSync(manifest)) return;
  let cmd;
  try { cmd = JSON.parse(fs.readFileSync(manifest, 'utf8')).authCommand; } catch { return; }
  if (!cmd) return;
  if (!autoYes) {
    const ans = (await ask(`Set up credentials for "${path.basename(installedDir)}" now? [y/N] `)).toLowerCase();
    if (ans !== 'y' && ans !== 'yes' && ans !== 'j' && ans !== 'ja') return;
  }
  const parts = cmd.split(' ');
  if (parts[0] === 'python') {
    const py = pythonCmd();
    if (!py) { console.error('  ! Python not found on PATH — skipping auth. Run manually:\n    cd ' + installedDir + ' && ' + cmd); return; }
    parts[0] = py;
  }
  console.log(`  running auth: ${cmd}`);
  spawnSync(parts[0], parts.slice(1), { cwd: installedDir, stdio: 'inherit' });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) { console.log(fs.readFileSync(__filename, 'utf8').split('*/')[0].replace(/^[\s\S]*?\/\*/, '')); return; }

  const skills = listSkills();
  if (args.list) { console.log('Available skills:\n  ' + skills.join('\n  ')); return; }

  // agent
  let agent = args.agent;
  if (!agent) {
    const keys = Object.keys(TARGETS);
    console.log('Target agent:');
    keys.forEach((k, i) => console.log(`  ${i + 1}) ${k}  (${TARGETS[k]})`));
    const pick = await ask('Choose [1-' + keys.length + ']: ');
    agent = keys[(parseInt(pick, 10) || 1) - 1];
  }
  if (!TARGETS[agent]) { console.error(`Unknown agent "${agent}". Use: ${Object.keys(TARGETS).join(', ')}`); process.exit(1); }

  // skill
  let skill = args.skill;
  if (!skill) {
    console.log('Skill:');
    console.log('  0) all');
    skills.forEach((s, i) => console.log(`  ${i + 1}) ${s}`));
    const pick = await ask('Choose [0-' + skills.length + ']: ');
    const n = parseInt(pick, 10);
    skill = (!n || n === 0) ? 'all' : skills[n - 1];
  }
  const chosen = skill === 'all' ? skills : [skill];
  for (const s of chosen) {
    if (!skills.includes(s)) { console.error(`Skill "${s}" not found. Available: ${skills.join(', ')}`); process.exit(1); }
  }

  console.log(`\nInstalling [${chosen.join(', ')}] into ${agent} (${TARGETS[agent]})\n`);
  const installed = chosen.map((s) => installSkill(s, TARGETS[agent], args.symlink));

  // auth: explicit --auth runs it; otherwise (interactive) confirm per skill; --yes without --auth skips
  for (const dir of installed) {
    if (args.auth) await maybeRunAuth(dir, true);
    else if (!args.yes) await maybeRunAuth(dir, false);
  }

  console.log('\nDone.');
  console.log('Skills needing secrets ship config.example.json — or run with --auth to enter keys now.');
}

main().catch((e) => { console.error(e.message || e); process.exit(1); });
