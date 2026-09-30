import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

for (const [format, entry, extension] of [["ESM", "../dist/index.js", "mts"], ["CommonJS", "../dist/cjs/index.js", "cts"]]) {
  test(`${format} session types require acquiring through the store and releasing through the lease`, t => {
    const directory = mkdtempSync(join(tmpdir(), "yrby-session-types-"));
    t.after(() => rmSync(directory, { recursive: true, force: true }));
    const file = join(directory, `consumer.${extension}`);
    writeFileSync(file, `
      import { DocumentSessionStore, type DocumentDescriptor } from ${JSON.stringify(fileURLToPath(new URL(entry, import.meta.url)))};
      declare const consumer: Parameters<typeof DocumentSessionStore.for>[0];
      const canonical = DocumentSessionStore.for(consumer);
      // @ts-expect-error Each consumer has one store, from DocumentSessionStore.for.
      new DocumentSessionStore(consumer);
      declare const store: DocumentSessionStore;
      declare const descriptor: DocumentDescriptor;
      const lease = store.acquire(descriptor);
      // @ts-expect-error changed() is internal to session transitions.
      store.changed(lease.session);
      const session = lease.session;
      lease.release();
      session.retry();
      session.discard();
      // @ts-expect-error Leases are acquired through the store.
      session.attach();
      // @ts-expect-error Releasing goes through the lease, which runs the cleanup.
      session.release(lease);
    `);
    const program = ts.createProgram([file], {
      noEmit: true, strict: true, skipLibCheck: true, types: [],
      target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.NodeNext,
      moduleResolution: ts.ModuleResolutionKind.NodeNext,
    });
    const diagnostics = ts.getPreEmitDiagnostics(program);
    assert.equal(diagnostics.length, 0, ts.formatDiagnostics(diagnostics, {
      getCanonicalFileName: name => name,
      getCurrentDirectory: () => directory,
      getNewLine: () => "\n",
    }));
  });
}
