// Checks the README's ```js examples against the built package: every
// example must parse as a module, and every name imported from
// "yrby-client" must exist in the real exports. Runs after `npm run
// build` (the test script builds first), so dist/ is present.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const readme = readFileSync(join(root, "README.md"), "utf8");
const blocks = [...readme.matchAll(/^```js\n([\s\S]*?)^```/gm)].map((m) => m[1]);

test("README has js examples", () => {
  assert.ok(blocks.length >= 3, `extraction found only ${blocks.length} blocks`);
});

test("README js examples parse as modules", () => {
  const dir = mkdtempSync(join(tmpdir(), "readme-js-"));
  try {
    blocks.forEach((block, i) => {
      const file = join(dir, `example_${i}.mjs`);
      writeFileSync(file, block);
      const check = spawnSync(process.execPath, ["--check", file], { encoding: "utf8" });
      assert.equal(check.status, 0, `example ${i + 1} failed to parse:\n${check.stderr}\n${block}`);
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("names imported from yrby-client exist in the real exports", async () => {
  const exported = new Set(Object.keys(await import("../dist/index.js")));
  const imported = new Set();
  for (const block of blocks) {
    for (const m of block.matchAll(/import\s*\{([^}]+)\}\s*from\s*["']yrby-client["']/g)) {
      m[1].split(",").forEach((name) => imported.add(name.trim().split(/\s+as\s+/)[0]));
    }
  }
  assert.ok(imported.size >= 1, "no yrby-client imports found in examples");
  for (const name of imported) {
    assert.ok(exported.has(name), `README imports { ${name} } from yrby-client, which exports: ${[...exported].join(", ")}`);
  }
});
