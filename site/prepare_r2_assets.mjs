// Move the files over the Cloudflare Pages limit (25 MiB) out of the site
// into an R2 upload folder, and write _routes.json so that the Pages
// Function serves exactly those paths from R2. Every other path stays a
// static asset, so an old R2 object never shadows a new file.
//
//   node site/prepare_r2_assets.mjs <site dir> <r2 upload dir>
import { mkdir, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { extname, join, relative } from "node:path";

const source = process.argv[2] ?? "site/dist";
const destination = process.argv[3] ?? "site/.r2-upload";
const limit = Number(process.env.PAGES_ASSET_LIMIT_BYTES ?? 24 * 1024 * 1024);
const supported = new Set([".pck", ".wasm"]);
const moved = [];

async function filesUnder(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await filesUnder(path)));
    else if (entry.isFile()) files.push(path);
  }
  return files;
}

await rm(destination, { force: true, recursive: true });

for (const path of await filesUnder(source)) {
  const metadata = await stat(path);
  if (metadata.size <= limit) continue;
  const assetPath = relative(source, path).replaceAll("\\", "/");
  if (!supported.has(extname(path).toLowerCase())) {
    throw new Error(`${assetPath} exceeds the Pages limit but the R2 function serves only .pck and .wasm`);
  }
  const target = join(destination, assetPath);
  await mkdir(join(target, ".."), { recursive: true });
  await rename(path, target);
  moved.push({ path: assetPath, bytes: metadata.size });
}

const routes = { version: 1, include: moved.map((m) => "/" + m.path), exclude: [] };
if (routes.include.length === 0) routes.include = ["/__no-r2-assets"];
await writeFile(join(source, "_routes.json"), JSON.stringify(routes, null, 2) + "\n");
console.log(JSON.stringify({ limit, moved }, null, 2));
