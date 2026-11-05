// Export the reference engine's golden cases + its committed geometry
// snapshots into reference.json for bench/parity.gd. Run with Node >= 23.6
// (type stripping): node bench/parity/export_reference.mjs <reference repo>
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const ref = process.argv[2] ?? 'B:/dev/games/godot-uxml-reference';
const golden = join(ref, 'vendor/uxml-preview/tests/golden');
const { CASES, PANEL } = await import(pathToFileURL(join(golden, 'cases.ts')).href);
let commit = 'unknown';
try { commit = execSync('git rev-parse HEAD', { cwd: ref }).toString().trim(); } catch {}
const out = { source: 'uxml-preview golden cases (vendor/uxml-preview/tests/golden)', commit, panel: PANEL, cases: [] };
for (const c of CASES) {
  const snap = join(golden, 'snapshots', `${c.name}.json`);
  out.cases.push({
    name: c.name,
    question: c.question,
    uxml: c.uxml,
    uss: c.uss,
    files: c.files ?? {},
    measuresText: !!c.measuresText,
    measuresResources: !!c.measuresResources,
    expected: existsSync(snap) ? JSON.parse(readFileSync(snap, 'utf8')) : null,
  });
}
writeFileSync(new URL('./reference.json', import.meta.url), JSON.stringify(out, null, 1));
console.log(`exported ${out.cases.length} cases from ${commit}`);
