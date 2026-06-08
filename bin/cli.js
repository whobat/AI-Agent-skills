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

function commandExists(c) {
  const finder = process.platform === 'win32' ? 'where' : 'which';
  return spawnSync(finder, [c], { stdio: 'ignore' }).status === 0;
}

// Install Python with the platform's package manager. Returns { ok, reason }.
function installPython() {
  const plat = process.platform;
  let cmd, cmdArgs, label;
  if (plat === 'win32') {
    if (!commandExists('winget')) return { ok: false, reason: 'winget not found' };
    cmd = 'winget';
    cmdArgs = ['install', '-e', '--id', 'Python.Python.3.12', '--source', 'winget',
      '--accept-package-agreements', '--accept-source-agreements'];
    label = 'winget install Python.Python.3.12';
  } else if (plat === 'darwin') {
    if (!commandExists('brew')) return { ok: false, reason: 'Homebrew (brew) not found' };
    cmd = 'brew'; cmdArgs = ['install', 'python']; label = 'brew install python';
  } else if (commandExists('apt-get')) {
    cmd = 'sudo'; cmdArgs = ['apt-get', 'install', '-y', 'python3']; label = 'sudo apt-get install -y python3';
  } else if (commandExists('dnf')) {
    cmd = 'sudo'; cmdArgs = ['dnf', 'install', '-y', 'python3']; label = 'sudo dnf install -y python3';
  } else {
    return { ok: false, reason: 'no supported package manager (winget/brew/apt-get/dnf)' };
  }
  console.log(`  installing Python via: ${label}`);
  const r = spawnSync(cmd, cmdArgs, { stdio: 'inherit' });
  return { ok: r.status === 0, reason: r.status === 0 ? null : `exit ${r.status}` };
}

// Returns a working python command, installing it first if missing. null if unavailable.
async function ensurePython(autoYes) {
  let py = pythonCmd();
  if (py) return py;
  console.log('  Python not found on PATH.');
  if (!autoYes) {
    const ans = (await ask('  Install Python now? [Y/n] ')).toLowerCase();
    if (ans === 'n' || ans === 'no' || ans === 'nej') return null;
  }
  const res = installPython();
  if (!res.ok) {
    console.error(`  ! Could not auto-install Python (${res.reason}). Install it manually: https://www.python.org/downloads/`);
    return null;
  }
  py = pythonCmd();
  if (!py) {
    console.log('  Python installed, but it is not on PATH for this session.');
    console.log('  Open a NEW terminal and re-run the installer (or the skill\'s auth command).');
    return null;
  }
  console.log(`  Python ready: ${py}`);
  return py;
}

function hasPyFile(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) { if (hasPyFile(path.join(dir, e.name))) return true; }
    else if (e.name.endsWith('.py')) return true;
  }
  return false;
}

// A skill needs Python if it ships .py scripts or its auth command runs python.
function skillNeedsPython(name) {
  const dir = path.join(SKILLS_DIR, name);
  const manifest = path.join(dir, 'skill.install.json');
  if (fs.existsSync(manifest)) {
    try {
      const cmd = (JSON.parse(fs.readFileSync(manifest, 'utf8')).authCommand || '').trim();
      if (cmd.startsWith('python')) return true;
    } catch { /* ignore malformed manifest */ }
  }
  return hasPyFile(dir);
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

// Install a skill's Python dependencies (from skill.install.json pipPackages).
function pipInstallForSkill(installedDir, py) {
  if (!py) return;
  const manifest = path.join(installedDir, 'skill.install.json');
  if (!fs.existsSync(manifest)) return;
  let m;
  try { m = JSON.parse(fs.readFileSync(manifest, 'utf8')); } catch { return; }
  const pkgs = Array.isArray(m.pipPackages) ? m.pipPackages : [];
  if (pkgs.length === 0) return;
  console.log(`  installing Python packages: ${pkgs.join(', ')}`);
  const r = spawnSync(py, ['-m', 'pip', 'install', '--disable-pip-version-check', ...pkgs], { stdio: 'inherit' });
  if (r.status !== 0) {
    console.error(`  ! pip install failed (exit ${r.status}). Run manually:\n    ${py} -m pip install ${pkgs.join(' ')}`);
  }
}

// Print where to obtain the skill's credentials (from skill.install.json authHelp).
function printAuthHelp(installedDir) {
  const manifest = path.join(installedDir, 'skill.install.json');
  if (!fs.existsSync(manifest)) return;
  let m;
  try { m = JSON.parse(fs.readFileSync(manifest, 'utf8')); } catch { return; }
  const help = Array.isArray(m.authHelp) ? m.authHelp : [];
  if (!m.authCommand && help.length === 0) return;
  console.log(`\nCredential setup for "${path.basename(installedDir)}":`);
  if (m.authCommand) console.log(`  run: ${m.authCommand}`);
  for (const line of help) console.log(`  ${line}`);
}

async function maybeRunAuth(installedDir, autoYes, py) {
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
    if (!py) { console.error('  ! Python not available — skipping auth. Run manually:\n    cd ' + installedDir + ' && ' + cmd); return; }
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

  // Ensure Python is present for any skill that needs it (.py scripts or a python auth command).
  let py = null;
  if (chosen.some(skillNeedsPython)) {
    py = await ensurePython(args.yes);
  }

  // Install each skill's Python dependencies
  for (const dir of installed) pipInstallForSkill(dir, py);

  // Always show where to get credentials for any skill that needs them
  for (const dir of installed) printAuthHelp(dir);

  // auth: explicit --auth runs it; otherwise (interactive) confirm per skill; --yes without --auth skips
  for (const dir of installed) {
    if (args.auth) await maybeRunAuth(dir, true, py);
    else if (!args.yes) await maybeRunAuth(dir, false, py);
  }

  console.log('\nDone.');
  console.log('Skills needing secrets ship config.example.json — or run with --auth to enter keys now.');
}

main().catch((e) => { console.error(e.message || e); process.exit(1); });
