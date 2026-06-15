#!/usr/bin/env node
// Validates every skill in skills/ against the Agent Skills specification
// (https://agentskills.io/specification) plus this repo's conventions.
//
// Spec rules enforced:
//   - SKILL.md exists with YAML frontmatter
//   - name: 1-64 chars, [a-z0-9-], no leading/trailing/consecutive hyphens,
//     must match the parent directory name
//   - description: 1-1024 chars, non-empty, no XML tags
//   - compatibility: 1-500 chars when present
//   - only spec-defined top-level frontmatter fields:
//     name, description, license, compatibility, metadata, allowed-tools
//
// Repo conventions enforced (allowed by the spec via `metadata`):
//   - license must be present (this is a public repo)
//   - metadata.version must be present (the installers' update detection keys on it)
//   - a "## Gotchas" section exists (in SKILL.md or REFERENCE.md) — domain pitfalls
//     so agents don't repeat known misdiagnoses
//
// Exit code 0 = all valid; 1 = violations (printed per skill).
'use strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SKILLS_DIR = path.join(REPO, 'skills');
const SPEC_FIELDS = new Set(['name', 'description', 'license', 'compatibility', 'metadata', 'allowed-tools']);

// Minimal YAML-subset parser for our frontmatter: top-level "key: value" scalars
// plus one level of nesting under a mapping key (e.g. metadata:).
function parseFrontmatter(raw) {
  const m = raw.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return null;
  const result = {};
  let currentMap = null;
  for (const line of m[1].split(/\r?\n/)) {
    if (!line.trim()) continue;
    const nested = line.match(/^\s+([\w-]+):\s*(.*)$/);
    const top = line.match(/^([\w-]+):\s*(.*)$/);
    if (top) {
      const [, key, value] = top;
      if (value === '') {
        result[key] = {};
        currentMap = result[key];
      } else {
        result[key] = value.replace(/^["']|["']$/g, '');
        currentMap = null;
      }
    } else if (nested && currentMap) {
      const [, key, value] = nested;
      currentMap[key] = value.replace(/^["']|["']$/g, '');
    }
  }
  return result;
}

let failures = 0;
const fail = (skill, msg) => { failures++; console.error(`  FAIL ${skill}: ${msg}`); };

// Skills are grouped under category subfolders (skills/<category>/<name>/SKILL.md). Discover
// each skill by its SKILL.md within two levels; the skill folder is its immediate parent.
function discover(dir, depth, found) {
  if (fs.existsSync(path.join(dir, 'SKILL.md'))) { found.push(dir); return; }
  if (depth <= 0) return;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) discover(path.join(dir, e.name), depth - 1, found);
  }
}
const skillDirs = [];
discover(SKILLS_DIR, 2, skillDirs);

const seenNames = new Map();   // name -> relative path, for global-uniqueness check
for (const skillDir of skillDirs) {
  const name = path.basename(skillDir);
  const rel = path.relative(REPO, skillDir).replace(/\\/g, '/');
  const skillMd = path.join(skillDir, 'SKILL.md');
  const fm = parseFrontmatter(fs.readFileSync(skillMd, 'utf8'));
  if (!fm) { fail(name, 'no YAML frontmatter found'); continue; }

  // names install into one flat namespace, so they must be globally unique
  if (seenNames.has(name)) fail(name, `duplicate skill name (also at ${seenNames.get(name)})`);
  else seenNames.set(name, rel);

  // name
  if (!fm.name) fail(name, 'frontmatter missing required field: name');
  else {
    if (fm.name !== name) fail(name, `name "${fm.name}" must match its own folder name "${name}" (${rel})`);
    if (fm.name.length > 64) fail(name, 'name exceeds 64 characters');
    if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(fm.name)) {
      fail(name, 'name must be lowercase [a-z0-9-], no leading/trailing/consecutive hyphens');
    }
  }

  // description
  if (!fm.description) fail(name, 'frontmatter missing required field: description');
  else {
    if (fm.description.length > 1024) fail(name, `description is ${fm.description.length} chars (max 1024)`);
    if (/<[^>]+>/.test(fm.description)) fail(name, 'description must not contain XML tags');
  }

  // compatibility
  if (fm.compatibility !== undefined && (fm.compatibility.length < 1 || fm.compatibility.length > 500)) {
    fail(name, `compatibility is ${fm.compatibility.length} chars (must be 1-500)`);
  }

  // only spec-defined top-level fields
  for (const key of Object.keys(fm)) {
    if (!SPEC_FIELDS.has(key)) fail(name, `non-spec frontmatter field: "${key}" (allowed: ${[...SPEC_FIELDS].join(', ')})`);
  }

  // repo conventions
  if (!fm.license) fail(name, 'license field missing (repo convention: required)');
  if (typeof fm.metadata !== 'object' || !fm.metadata.version) {
    fail(name, 'metadata.version missing (installers key update detection on it)');
  } else if (!/^\d+\.\d+\.\d+$/.test(fm.metadata.version)) {
    fail(name, `metadata.version "${fm.metadata.version}" is not semver (x.y.z)`);
  }

  // repo convention: every skill documents its domain pitfalls in a "## Gotchas" section
  // (in SKILL.md or, preferably for script-backed skills, REFERENCE.md) so agents don't
  // repeat known misdiagnoses. Accept "## Gotchas" or "### Gotchas", optional trailing text.
  const refMd = path.join(skillDir, 'REFERENCE.md');
  const bodyForGotchas =
    fs.readFileSync(skillMd, 'utf8') +
    (fs.existsSync(refMd) ? '\n' + fs.readFileSync(refMd, 'utf8') : '');
  if (!/^#{2,3}\s+Gotchas\b/im.test(bodyForGotchas)) {
    fail(name, 'missing a "## Gotchas" section (in SKILL.md or REFERENCE.md) — document the domain pitfalls so agents don\'t repeat known misdiagnoses');
  }
}

// Every category folder that holds skills must be listed in the plugin's `skills` array,
// or the Claude Code marketplace would not discover those skills.
const categories = new Set();
for (const d of skillDirs) {
  const parts = path.relative(SKILLS_DIR, d).replace(/\\/g, '/').split('/');
  if (parts.length >= 2) categories.add(parts[0]);  // skills/<category>/<name>
}
const pluginManifest = path.join(REPO, '.claude-plugin', 'plugin.json');
if (fs.existsSync(pluginManifest)) {
  let listed = [];
  try {
    const m = JSON.parse(fs.readFileSync(pluginManifest, 'utf8'));
    listed = (Array.isArray(m.skills) ? m.skills : (m.skills ? [m.skills] : []))
      .map((s) => s.replace(/^\.\//, '').replace(/^skills\//, '').replace(/\/$/, ''));
  } catch { fail('plugin.json', 'is not valid JSON'); }
  for (const cat of categories) {
    if (!listed.includes(cat)) {
      fail('plugin.json', `category "${cat}" is not in .claude-plugin/plugin.json "skills" (marketplace would miss its skills)`);
    }
  }
}

if (failures > 0) {
  console.error(`\n${failures} violation(s) across ${skillDirs.length} skills.`);
  process.exit(1);
}
console.log(`OK: ${skillDirs.length} skills pass the Agent Skills spec + repo conventions.`);
