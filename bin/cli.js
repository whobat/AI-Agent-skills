#!/usr/bin/env node
/*
 * AI-Agent-Skills installer
 *
 *   npx github:whobat/AI-Agent-skills                      # interactive
 *   npx github:whobat/AI-Agent-skills --agent claude --skill all
 *   npx github:whobat/AI-Agent-skills --agent codex --skill 7pace-time-tracker --auth
 *
 * Flags:
 *   --agent <claude|codex|opencode|all>   target agent(s) (prompted if omitted)
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

// "(0.9.0 -> 1.0.0)" / "(new, 1.0.0)" / "(1.0.0, reinstalled)" for the install log line.
function versionNote(prev, repo) {
  if (!repo) return '';
  if (prev && prev !== repo) return ` (${prev} -> ${repo})`;
  if (prev) return ` (${repo}, reinstalled)`;
  return ` (new, ${repo})`;
}

function installSkill(name, destDir, symlink) {
  const src = path.join(SKILLS_DIR, name);
  const dest = path.join(destDir, name);
  const note = versionNote(skillVersion(dest), skillVersion(src));
  fs.mkdirSync(destDir, { recursive: true });
  fs.rmSync(dest, { recursive: true, force: true });
  if (symlink) {
    fs.symlinkSync(src, dest, 'junction');
    console.log(`  linked  ${name} -> ${dest}${note}`);
  } else {
    fs.cpSync(src, dest, { recursive: true });
    // never install real secrets / caches
    fs.rmSync(path.join(dest, 'config.json'), { force: true });
    rmAll(dest, 'config.json');
    rmAll(dest, '__pycache__');
    console.log(`  copied  ${name} -> ${dest}${note}`);
  }
  return dest;
}

// "[installed 1.0.0 -> latest 1.0.2]" / "[installed 1.0.2, up to date]" / "[v1.0.2, not installed]"
function skillStatusNote(name, agent) {
  const repoV = skillVersion(path.join(SKILLS_DIR, name));
  if (!repoV) return '';
  const instV = agent && TARGETS[agent] ? skillVersion(path.join(TARGETS[agent], name)) : null;
  if (instV && instV !== repoV) return `[installed ${instV} -> latest ${repoV}]`;
  if (instV) return `[installed ${instV}, up to date]`;
  return `[v${repoV}${agent ? ', not installed' : ''}]`;
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

// Resolve a manifest's configPath (e.g. "~/.7pace/config.json") to an absolute path. null if undeclared.
function resolveConfigPath(p) {
  if (!p) return null;
  if (p === '~') return os.homedir();
  if (p.startsWith('~/') || p.startsWith('~\\')) return path.join(os.homedir(), p.slice(2));
  return path.resolve(p);
}

// Print where to obtain the skill's credentials (from skill.install.json authHelp).
// If the skill's config file already exists, say so instead of dumping setup instructions.
function printAuthHelp(installedDir) {
  const manifest = path.join(installedDir, 'skill.install.json');
  if (!fs.existsSync(manifest)) return;
  let m;
  try { m = JSON.parse(fs.readFileSync(manifest, 'utf8')); } catch { return; }
  const help = Array.isArray(m.authHelp) ? m.authHelp : [];
  if (!m.authCommand && help.length === 0) return;
  const cfg = resolveConfigPath(m.configPath);
  if (cfg && fs.existsSync(cfg)) {
    console.log(`\nCredentials for "${path.basename(installedDir)}": already configured (${cfg}).`);
    return;
  }
  console.log(`\nCredential setup for "${path.basename(installedDir)}":`);
  if (m.authCommand) console.log(`  run: ${m.authCommand}`);
  for (const line of help) console.log(`  ${line}`);
}

// Run a skill's credential setup (authCommand). When its config file already exists, the
// user is asked whether to update the tokens or keep them; default is keep and continue.
async function maybeRunAuth(installedDir, opts, py) {
  const manifest = path.join(installedDir, 'skill.install.json');
  if (!fs.existsSync(manifest)) return;
  let m;
  try { m = JSON.parse(fs.readFileSync(manifest, 'utf8')); } catch { return; }
  const cmd = m.authCommand;
  if (!cmd) return;
  const name = path.basename(installedDir);
  const yesAnswers = ['y', 'yes', 'j', 'ja'];
  const cfg = resolveConfigPath(m.configPath);
  if (cfg && fs.existsSync(cfg)) {
    if (!opts.interactive) {
      console.log(`  ${name}: credentials already configured (${cfg}) — skipping auth.`);
      return;
    }
    const ans = (await ask(`Credentials for "${name}" already configured (${cfg}). Update tokens? [y/N] `)).toLowerCase();
    if (!yesAnswers.includes(ans)) { console.log('  keeping existing credentials.'); return; }
  } else if (!opts.explicit) {
    if (!opts.interactive) return;
    const ans = (await ask(`Set up credentials for "${name}" now? [y/N] `)).toLowerCase();
    if (!yesAnswers.includes(ans)) return;
  }
  const parts = cmd.split(' ');
  if (parts[0] === 'python') {
    if (!py) { console.error('  ! Python not available — skipping auth. Run manually:\n    cd ' + installedDir + ' && ' + cmd); return; }
    parts[0] = py;
  }
  console.log(`  running auth: ${cmd}`);
  spawnSync(parts[0], parts.slice(1), { cwd: installedDir, stdio: 'inherit' });
}

// Read 'version:' from a skill's SKILL.md frontmatter. null if absent.
function skillVersion(dir) {
  const md = path.join(dir, 'SKILL.md');
  if (!fs.existsSync(md)) return null;
  let inFront = false;
  for (const line of fs.readFileSync(md, 'utf8').split(/\r?\n/)) {
    if (/^---\s*$/.test(line)) { if (inFront) break; inFront = true; continue; }
    if (inFront) { const m = line.match(/^\s*version:\s*(.+?)\s*$/); if (m) return m[1].trim(); }
  }
  return null;
}

function parseSemver(s) {
  const m = String(s).match(/(\d+)\.(\d+)(?:\.(\d+))?/);
  return m ? [+m[1], +m[2], +(m[3] || 0)] : null;
}
function semverGte(a, b) {
  for (let i = 0; i < 3; i++) { if ((a[i] || 0) > (b[i] || 0)) return true; if ((a[i] || 0) < (b[i] || 0)) return false; }
  return true;
}

// Is a declared requirement satisfied (on PATH or at a known file path, and >= minVersion when checkable)?
function requirementPresent(req) {
  if (Array.isArray(req.detectPaths)) {
    for (const p of req.detectPaths) {
      if (fs.existsSync(p)) return true;
    }
  }
  if (!req.detect) return false;
  if (!commandExists(req.detect)) return false;
  if (req.minVersion) {
    let r = spawnSync(req.detect, ['--version'], { encoding: 'utf8' });
    let text = `${r.stdout || ''}${r.stderr || ''}`;
    if (r.status !== 0 || !text.trim()) {
      r = spawnSync(req.detect, ['-v'], { encoding: 'utf8' });
      text = `${r.stdout || ''}${r.stderr || ''}`;
    }
    const have = parseSemver(text); const need = parseSemver(req.minVersion);
    if (have && need) return semverGte(have, need);
  }
  return true;
}

// Download the latest GitHub-released MSI for a requirement and install it silently (Windows).
async function installFromGitHubMsi(req) {
  if (!req.githubRepo) return false;
  const arch = ({ x64: 'x64', arm64: 'arm64', ia32: 'x86' })[process.arch] || 'x64';
  try {
    console.log(`  fetching latest ${req.name} MSI from github.com/${req.githubRepo} ...`);
    const rel = await (await fetch(`https://api.github.com/repos/${req.githubRepo}/releases/latest`,
      { headers: { 'User-Agent': 'ai-agent-skills-installer' } })).json();
    const asset = (rel.assets || []).find((a) => new RegExp(`win-${arch}\\.msi$`).test(a.name));
    if (!asset) { console.error(`  ! No win-${arch} MSI asset found. Install manually: ${req.url}`); return false; }
    const tmp = path.join(os.tmpdir(), asset.name);
    console.log(`  downloading ${asset.name} ...`);
    fs.writeFileSync(tmp, Buffer.from(await (await fetch(asset.browser_download_url)).arrayBuffer()));
    console.log(`  installing: msiexec /i ${tmp} /quiet /norestart`);
    return spawnSync('msiexec', ['/i', tmp, '/quiet', '/norestart'], { stdio: 'inherit' }).status === 0;
  } catch (e) {
    console.error(`  ! MSI install failed: ${e.message}. Install manually: ${req.url}`);
    return false;
  }
}

// Install a missing requirement with the platform's package manager (winget/MSI, brew).
async function installRequirement(req) {
  if (process.platform === 'win32') {
    if (req.wingetId && commandExists('winget')) {
      console.log(`  installing ${req.name} via: winget install ${req.wingetId}`);
      const r = spawnSync('winget', ['install', '-e', '--id', req.wingetId, '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements'], { stdio: 'inherit' });
      if (r.status === 0) return true;
      console.error('  winget failed; trying MSI fallback.');
    }
    return installFromGitHubMsi(req);
  }
  if (process.platform === 'darwin') {
    if (req.brewCask && commandExists('brew')) {
      console.log(`  installing ${req.name} via: brew install --cask ${req.brewCask}`);
      return spawnSync('brew', ['install', '--cask', req.brewCask], { stdio: 'inherit' }).status === 0;
    }
    console.error(`  ! Homebrew not found. Install ${req.name} manually: ${req.url}`);
    return false;
  }
  console.error(`  ! Cannot auto-install ${req.name} on this platform. Install manually: ${req.url}`);
  return false;
}

// Ensure every runtime requirement declared in a skill's skill.install.json is present.
async function ensureRequirements(installedDir, autoYes) {
  const manifest = path.join(installedDir, 'skill.install.json');
  if (!fs.existsSync(manifest)) return;
  let m;
  try { m = JSON.parse(fs.readFileSync(manifest, 'utf8')); } catch { return; }
  const reqs = Array.isArray(m.requirements) ? m.requirements : [];
  for (const req of reqs) {
    if (!req || (!req.detect && !Array.isArray(req.detectPaths))) continue;
    if (requirementPresent(req)) { console.log(`  requirement OK: ${req.name}`); continue; }
    // warnOnly requirements (e.g. NAV 2009 finsql.exe) cannot be auto-installed — warn and continue.
    if (req.warnOnly) {
      console.warn(`  ! WARNING: ${req.name} not found.`);
      if (Array.isArray(req.detectPaths)) console.warn(`    checked: ${req.detectPaths.join('; ')}`);
      if (req.help) console.warn(`    ${req.help}`);
      if (req.url) console.warn(`    ${req.url}`);
      continue;
    }
    console.log(`  requirement missing: ${req.name}`);
    if (!autoYes) {
      const ans = (await ask(`  Install ${req.name} now? [Y/n] `)).toLowerCase();
      if (ans === 'n' || ans === 'no' || ans === 'nej') { console.log(`  skipped — install manually: ${req.url}`); continue; }
    }
    await installRequirement(req);
    if (requirementPresent(req)) console.log(`  ${req.name} ready`);
    else console.log(`  ${req.name} installed but not on PATH for this session. Open a NEW terminal. (${req.url})`);
  }
}

// Offer to update already-installed skills (from this repo) whose version differs from the repo.
async function updateOutdated(destDir, chosenNames, autoYes) {
  if (!fs.existsSync(destDir)) return;
  const candidates = [];
  for (const e of fs.readdirSync(destDir, { withFileTypes: true })) {
    if (!e.isDirectory() || chosenNames.includes(e.name)) continue;
    const srcDir = path.join(SKILLS_DIR, e.name);
    if (!fs.existsSync(srcDir)) continue;
    const instV = skillVersion(path.join(destDir, e.name));
    const repoV = skillVersion(srcDir);
    if (repoV && instV !== repoV) candidates.push({ name: e.name, from: instV || 'unknown', to: repoV });
  }
  if (candidates.length === 0) return;
  console.log('\nUpdates available for already-installed skills:');
  for (const c of candidates) console.log(`  ${c.name}: ${c.from} -> ${c.to}`);
  if (!autoYes) {
    const ans = (await ask('Update these now? [Y/n] ')).toLowerCase();
    if (ans === 'n' || ans === 'no' || ans === 'nej') return;
  }
  for (const c of candidates) {
    const dest = path.join(destDir, c.name);
    const cfg = path.join(dest, 'config.json');
    const keep = fs.existsSync(cfg) ? fs.readFileSync(cfg) : null;
    fs.rmSync(dest, { recursive: true, force: true });
    fs.cpSync(path.join(SKILLS_DIR, c.name), dest, { recursive: true });
    rmAll(dest, 'config.json');
    rmAll(dest, '__pycache__');
    if (keep !== null) fs.writeFileSync(cfg, keep);
    console.log(`  updated ${c.name} -> ${c.to}`);
    await ensureRequirements(dest, autoYes);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) { console.log(fs.readFileSync(__filename, 'utf8').split('*/')[0].replace(/^[\s\S]*?\/\*/, '')); return; }

  const skills = listSkills();
  if (args.list) {
    // With --agent, also show the installed version vs the repo's latest.
    console.log('Available skills:');
    for (const s of skills) console.log(`  ${s}  ${skillStatusNote(s, args.agent)}`);
    return;
  }

  // agent ('all' = every supported agent)
  let agent = args.agent;
  if (!agent) {
    const keys = Object.keys(TARGETS);
    console.log('Target agent:');
    console.log('  0) all  (every agent below)');
    keys.forEach((k, i) => console.log(`  ${i + 1}) ${k}  (${TARGETS[k]})`));
    const pick = await ask('Choose [0-' + keys.length + ']: ');
    const n = parseInt(pick, 10);
    agent = n === 0 ? 'all' : keys[(n || 1) - 1];
  }
  if (agent !== 'all' && !TARGETS[agent]) {
    console.error(`Unknown agent "${agent}". Use: ${Object.keys(TARGETS).join(', ')}, all`);
    process.exit(1);
  }
  const agents = agent === 'all' ? Object.keys(TARGETS) : [agent];

  // skill
  let skill = args.skill;
  if (!skill) {
    console.log('Skill:');
    console.log('  0) all');
    skills.forEach((s, i) => console.log(`  ${i + 1}) ${s}  ${skillStatusNote(s, agent === 'all' ? null : agent)}`));
    const pick = await ask('Choose [0-' + skills.length + ']: ');
    const n = parseInt(pick, 10);
    skill = (!n || n === 0) ? 'all' : skills[n - 1];
  }
  const chosen = skill === 'all' ? skills : [skill];
  for (const s of chosen) {
    if (!skills.includes(s)) { console.error(`Skill "${s}" not found. Available: ${skills.join(', ')}`); process.exit(1); }
  }

  for (const a of agents) {
    console.log(`\nInstalling [${chosen.join(', ')}] into ${a} (${TARGETS[a]})\n`);
    for (const s of chosen) installSkill(s, TARGETS[a], args.symlink);
  }

  // Machine-level steps (runtimes, pip, credentials) run once per skill — the manifests are
  // identical across agents, so use each skill's copy under the first agent dir.
  const skillDirs = chosen.map((s) => path.join(TARGETS[agents[0]], s));

  // Ensure declared runtime requirements (e.g. PowerShell 7) for each installed skill
  for (const dir of skillDirs) await ensureRequirements(dir, args.yes);

  // Ensure Python is present for any skill that needs it (.py scripts or a python auth command).
  let py = null;
  if (chosen.some(skillNeedsPython)) {
    py = await ensurePython(args.yes);
  }

  // Install each skill's Python dependencies
  for (const dir of skillDirs) pipInstallForSkill(dir, py);

  // Always show where to get credentials for any skill that needs them
  for (const dir of skillDirs) printAuthHelp(dir);

  // auth: --auth runs setup directly; otherwise (interactive) confirm per skill. Skills whose
  // config already exists are detected — the user chooses update or keep (keep is the default).
  for (const dir of skillDirs) {
    await maybeRunAuth(dir, { explicit: args.auth, interactive: !args.yes }, py);
  }

  // Offer to update other already-installed skills whose repo version changed
  for (const a of agents) await updateOutdated(TARGETS[a], chosen, args.yes);

  console.log('\nDone.');
  console.log('Skills needing secrets ship config.example.json — or run with --auth to enter keys now.');
}

main().catch((e) => { console.error(e.message || e); process.exit(1); });
