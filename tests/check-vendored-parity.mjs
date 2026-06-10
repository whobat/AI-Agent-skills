#!/usr/bin/env node
// Vendored-file parity check.
//
// Skills must be self-contained (Agent Skills spec + plugin caching + per-skill
// installs), so scripts shared between skills are VENDORED — copied byte-identical
// into each skill's scripts/ folder. This check fails CI when copies drift.
//
// To change a vendored script: edit ONE copy, then copy it over the others
// (the groups below list every copy), and bump metadata.version in EVERY skill
// that received the change.
'use strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const GROUPS = [
  [
    'skills/nav2009-sql-performance/scripts/Invoke-SqlPerfTriage.ps1',
    'skills/sqlserver-perf-triage/scripts/Invoke-SqlPerfTriage.ps1',
    'skills/ax2012-sql-performance/scripts/Invoke-SqlPerfTriage.ps1',
  ],
  [
    'skills/nav2009-sql-performance/scripts/Invoke-SqlPerfTriage.Tests.ps1',
    'skills/sqlserver-perf-triage/scripts/Invoke-SqlPerfTriage.Tests.ps1',
    'skills/ax2012-sql-performance/scripts/Invoke-SqlPerfTriage.Tests.ps1',
  ],
];

// Hash with normalized line endings so CRLF/LF checkout differences don't false-positive.
const hash = (p) => crypto.createHash('sha256')
  .update(fs.readFileSync(p, 'utf8').replace(/\r\n/g, '\n'))
  .digest('hex');

let failures = 0;
for (const group of GROUPS) {
  const hashes = group.map((rel) => {
    const abs = path.join(REPO, rel);
    if (!fs.existsSync(abs)) { failures++; console.error(`  FAIL missing vendored copy: ${rel}`); return null; }
    return hash(abs);
  });
  const reference = hashes.find((h) => h !== null);
  group.forEach((rel, i) => {
    if (hashes[i] !== null && hashes[i] !== reference) {
      failures++;
      console.error(`  FAIL vendored copy drifted: ${rel} (differs from ${group[0]})`);
    }
  });
}

if (failures > 0) {
  console.error(`\n${failures} parity violation(s). Copy the canonical file over the drifted copies and bump the affected skills' versions.`);
  process.exit(1);
}
console.log(`OK: ${GROUPS.length} vendored file groups are byte-identical across skills.`);
