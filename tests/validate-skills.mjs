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

const dirs = fs.readdirSync(SKILLS_DIR, { withFileTypes: true }).filter((d) => d.isDirectory());
for (const dir of dirs) {
  const name = dir.name;
  const skillMd = path.join(SKILLS_DIR, name, 'SKILL.md');
  if (!fs.existsSync(skillMd)) { fail(name, 'SKILL.md missing'); continue; }
  const fm = parseFrontmatter(fs.readFileSync(skillMd, 'utf8'));
  if (!fm) { fail(name, 'no YAML frontmatter found'); continue; }

  // name
  if (!fm.name) fail(name, 'frontmatter missing required field: name');
  else {
    if (fm.name !== name) fail(name, `name "${fm.name}" must match directory name "${name}"`);
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
}

if (failures > 0) {
  console.error(`\n${failures} violation(s) across ${dirs.length} skills.`);
  process.exit(1);
}
console.log(`OK: ${dirs.length} skills pass the Agent Skills spec + repo conventions.`);
