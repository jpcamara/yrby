// Four real Chrome sessions type through the fixture editor while Turbo or
// Turbolinks navigates, caches, and restores pages. Both consumer libraries use
// the real Rails ActionCable endpoint; this does not emulate an AnyCable gateway.
import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { mkdir, open, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const exec = promisify(execFile);
const root = fileURLToPath(new URL("../../../", import.meta.url));
const ab = process.env.AB_BIN || "agent-browser";
const source = {
  commit: (await exec("git", ["rev-parse", "HEAD"], { cwd: root })).stdout.trim(),
  modified: Boolean((await exec("git", ["status", "--porcelain"], { cwd: root })).stdout.trim()),
};
const outputRoot = `${root}tmp/browser-collaboration/${Date.now()}-${process.pid}`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const frameworks = process.env.FRAMEWORK ? [process.env.FRAMEWORK] : ["turbo", "turbolinks"];
const transports = process.env.CONSUMER ? [process.env.CONSUMER] : ["actioncable", "anycable"];
assert.ok(frameworks.every(value => ["turbo", "turbolinks"].includes(value)));
assert.ok(transports.every(value => ["actioncable", "anycable"].includes(value)));

async function run(framework, transport, port) {
  const label = `${framework}-${transport}`;
  const output = `${outputRoot}/${label}`;
  const assets = `${output}/assets`, base = `http://127.0.0.1:${port}`;
  const sessions = Array.from({ length: 4 }, (_, i) => `yrby-${label}-${process.pid}-${i}`);
  const reader = `${sessions[0]}-reader`;
  const expected = [0, 0, 0, 0], checks = [], typing = [];
  const started = Date.now();
  await mkdir(assets, { recursive: true });
  const entry = framework === "turbo" ? "client.js" : "client_turbolinks.js";
  await build({ entryPoints: [fileURLToPath(new URL(entry, import.meta.url))], bundle: true,
    splitting: true, format: "esm", outdir: assets });
  const log = await open(`${output}/server.log`, "w");
  const server = spawn("bundle", ["exec", "ruby", "-Ilib", "test/browser/app.rb"], {
    cwd: root, env: { ...process.env, PORT: String(port), BROWSER_ASSETS: assets, BROWSER_FRAMEWORK: framework,
      DATABASE_URL: `sqlite3:${output}/fixture.sqlite3` }, stdio: ["ignore", log.fd, log.fd],
  });
  let serverError;
  server.on("error", error => { serverError = error; });
  async function browser(who, ...args) {
    const session = typeof who === "number" ? sessions[who] : who;
    const { stdout } = await exec(ab, ["--session", session, "--json", ...args], { timeout: 40000, maxBuffer: 2 ** 20 });
    const response = JSON.parse(stdout);
    assert.ok(response.success, `${label} ${session} ${args[0]}: ${JSON.stringify(response.error)}`);
    return response.data;
  }
  const evaluate = (who, code) => browser(who, "eval", "-b", Buffer.from(`{\n${code}\n}`).toString("base64")).then(data => data.result);
  const wait = (who, code) => browser(who, "wait", "--fn", code);
  const check = (name, ok) => { assert.ok(ok, `${label}: ${name}`); checks.push(name); console.log(`PASS ${label}: ${name}`); };
  const state = async () => {
    const response = await fetch(`${base}/state/body`);
    assert.equal(response.status, 200);
    return response.json();
  };
  const snapshot = who => evaluate(who, `(() => {
    const el = document.querySelector('#body-doc'), session = el?.session;
    return { path: location.pathname, context: window.stress?.context,
      text: el?.doc?.getText('content').toString(), input: el?.querySelector('textarea')?.value,
      synced: el?.provider?.synced, pending: el?.provider?.hasPending,
      mounts: el?.mountCount, unmounts: el?.unmountCount || 0, inert: el?.inert,
      errors: window.stress?.errors, navigation: window.stress?.navigation, inputs: window.stress?.inputs,
      retired: [...(window.stress?.sessions || [])].filter(value => value !== session).map(value => ({
        state: value.state, pending: value.hasPending, destroyed: value.doc.isDestroyed,
        timerActive: stress.intervals.has(value.provider.awareness._checkInterval)
      })) };
  })()`);
  async function eventually(name, fn, timeout = 30000) {
    const end = Date.now() + timeout;
    while (Date.now() < end) { if (await fn()) return; await sleep(200); }
    throw new Error(`${label}: timed out waiting for ${name}`);
  }
  const count = (text, digit) => text.split(digit).length - 1;
  async function converge(name) {
    let snapshots, saved;
    await eventually(name, async () => {
      snapshots = await Promise.all(sessions.map(snapshot));
      saved = await state();
      const text = snapshots[0].text;
      return typeof text === "string" && snapshots.every(value => value.synced && !value.pending &&
        !value.inert && value.text === text && value.input === text) && saved.text === text &&
        text.length === expected.reduce((a, b) => a + b, 0) && expected.every((n, i) => count(text, String(i + 1)) === n);
    });
    check(`${name}: all four editors and Ruby agree, every keystroke saved exactly once`, true);
    check(`${name}: one editor binding per element`, snapshots.every(value => value.mounts - value.unmounts === 1));
    return snapshots;
  }
  async function type(who, amount) {
    await wait(who, `document.querySelector('#body-doc')?.querySelector('textarea')?.disabled === false`);
    await browser(who, "click", 'textarea[aria-label="Body"]');
    await evaluate(who, `const input = document.querySelector('#body-doc textarea'); input.setSelectionRange(input.value.length, input.value.length);`);
    const start = Date.now();
    await browser(who, "keyboard", "type", String(who + 1).repeat(amount));
    expected[who] += amount;
    // The CLI can finish before Chrome dispatches the final keyboard events.
    await wait(who, `document.querySelector('#body-doc').doc.getText('content').toString().split('${who + 1}').length - 1 === ${expected[who]}`);
    typing.push({ who, start, end: Date.now(), amount });
  }
  const batch = (who, amount) => Promise.all(who.map(index => type(index, amount)));
  const rounds = async (who, times, amount) => { for (let i = 0; i < times; i++) await batch(who, amount); };
  async function away(who) {
    await browser(who, "find", "text", "Away", "click");
    await wait(who, `location.pathname === '/away' && !document.querySelector('yrby-document')`);
  }
  async function back(who) {
    await browser(who, "back");
    await wait(who, `location.pathname === '/' && document.querySelector('#body-doc')?.doc && !document.querySelector('#body-doc textarea').disabled`);
  }
  async function editor(who) {
    await browser(who, "find", "text", "Editor", "click");
    await wait(who, `location.pathname === '/' && document.querySelector('#body-doc')?.provider?.synced && !document.querySelector('#body-doc').inert`);
  }
  async function offline(who) {
    await evaluate(who, `window.parked = document.querySelector('#body-doc').session;
      const consumer = parked.provider.consumer;
      if (consumer.connection) {
        const open = consumer.connection.open; consumer.connection.open = () => false;
        stress.reconnect = () => { consumer.connection.open = open; consumer.connect(); };
      } else {
        const connect = consumer.cable.connect; consumer.cable.connect = async () => {};
        stress.reconnect = () => { consumer.cable.connect = connect; consumer.connect(); };
      }
      consumer.disconnect();`);
    await wait(who, `!parked.provider.synced`);
  }
  const online = who => evaluate(who, `stress.reconnect();`);
  try {
    await eventually("Rails boot", async () => {
      if (serverError) throw serverError;
      if (server.exitCode !== null) throw new Error(`Rails exited ${server.exitCode}; see ${output}/server.log`);
      try { return (await fetch(base)).ok; } catch { return false; }
    });
    // Start away from the editor so consumer selection precedes element binding.
    for (let i = 0; i < sessions.length; i++) {
      await browser(i, "open", `${base}/away`);
      await evaluate(i, `(async () => { window.stress = { context: crypto.randomUUID(), intervals: new Set(), sessions: new Set(), errors: [], navigation: [], inputs: [] };
        const set = window.setInterval, clear = window.clearInterval;
        window.setInterval = (...args) => { const id = set(...args); stress.intervals.add(id); return id; };
        window.clearInterval = id => { stress.intervals.delete(id); return clear(id); };
        window.addEventListener('error', event => stress.errors.push(String(event.error || event.message)));
        window.addEventListener('unhandledrejection', event => stress.errors.push(String(event.reason)));
        document.addEventListener('${framework}:load', () => stress.navigation.push({ path: location.pathname, at: Date.now() }));
        document.addEventListener('input', ({ target }) => { if (target.closest('#body-doc')) stress.inputs.push(Date.now()); });
        document.addEventListener('yrby:synced', ({ target, detail }) => {
          if (target.id === 'body-doc') stress.sessions.add(detail.session);
        });
        await fetch('/');
        ${transport === "anycable" ? 'YrbyDocumentElement.consumer = await anyCableConsumer();' : ''} })()`);
      await editor(i);
      check(`browser ${i + 1} awareness timer is tracked before cleanup`, await evaluate(i,
        `stress.intervals.has(document.querySelector('#body-doc').provider.awareness._checkInterval)`));
      check(`browser ${i + 1} runs ${framework} with ${transport}`, await evaluate(i,
        `!!window.${framework === "turbo" ? "Turbo" : "Turbolinks"} && !window.${framework === "turbo" ? "Turbolinks" : "Turbo"} && ${transport === "anycable" ? '!!document.querySelector("#body-doc").provider.consumer.cable' : '!!document.querySelector("#body-doc").provider.consumer.connection'}`));
    }
    const contexts = await Promise.all(sessions.map(who => evaluate(who, "stress.context")));
    await batch([0, 1, 2, 3], 12);
    await converge("simultaneous typing");

    await evaluate(0, `window.held = document.querySelector('#body-doc').session;
      const protocol = held.provider.session, ack = protocol.acknowledge.bind(protocol), ids = [];
      protocol.acknowledge = id => ids.push(id);
      stress.releaseAcks = () => { protocol.acknowledge = ack; ids.forEach(ack); };`);
    await batch([0, 1, 2, 3], 8);
    await eventually("held edit persisted", async () => count((await state()).text, "1") === expected[0]);
    check("real server ACKs are held while delivery remains pending", await evaluate(0, "held.hasPending") && count((await state()).text, "1") === expected[0]);
    await Promise.all([
      rounds([1, 2, 3], 3, 6),
      (async () => {
        await away(0);
        check("unacknowledged session survives leaving the page", await evaluate(0, "held.hasPending && !held.doc.isDestroyed"));
        await back(0);
        check("history restores the same pending session", await evaluate(0, "document.querySelector('#body-doc').session === held"));
        await away(0); await back(0);
      })(),
    ]);
    await evaluate(0, "stress.releaseAcks()");
    await converge("ACK delay plus repeated history navigation");

    await Promise.all([offline(0), offline(1)]);
    const beforePartition = [...expected];
    await batch([0, 1, 2, 3], 12);
    check("partitioned browsers retain edits absent from the server", await evaluate(0, "parked.hasPending") &&
      await evaluate(1, "parked.hasPending") && count((await state()).text, "1") === beforePartition[0] &&
      count((await state()).text, "2") === beforePartition[1]);
    await Promise.all([away(0), away(1), rounds([2, 3], 2, 8)]);
    await back(0);
    check("offline history restore keeps its original pending document", await evaluate(0, "document.querySelector('#body-doc').session === parked && parked.hasPending"));
    await batch([0], 5);
    await Promise.all([online(0), online(1), batch([2, 3], 8)]);
    await wait(1, "parked.state === 'closed' && parked.doc.isDestroyed && !parked.hasPending");
    check("pending edits drain and dispose while their editor is on another page", true);
    await editor(1);
    await converge("two offline writers rejoin during peer edits");

    await offline(0); await type(0, 6); await away(0);
    const holdFresh = framework === "turbo" ? `const original = window.fetch;
      window.fetch = (...args) => new URL(args[0].url || args[0], location.href).pathname === '/'
        ? new Promise(resolve => { stress.releaseFresh = () => { window.fetch = original; resolve(original(...args)); }; })
        : original(...args); Turbo.visit('/');` : `const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) { this.stressPath = new URL(url, location.href).pathname; return open.call(this, method, url, ...rest); };
      XMLHttpRequest.prototype.send = function(...args) {
        if (this.stressPath !== '/') return send.apply(this, args);
        stress.releaseFresh = () => { XMLHttpRequest.prototype.open = open; XMLHttpRequest.prototype.send = send; send.apply(this, args); };
      }; Turbolinks.visit('/');`;
    await evaluate(0, holdFresh);
    await wait(0, `document.documentElement.hasAttribute('data-${framework}-preview') && !!document.querySelector('#body-doc') && !!stress.releaseFresh`);
    check("cached preview is inert and has no document or subscription", await evaluate(0, `window.preview = document.querySelector('#body-doc'); preview.inert && !preview.doc && !preview.provider`));
    await batch([1, 2, 3], 10);
    check("outgoing offline edits survive while peers edit behind the preview", await evaluate(0, "parked.hasPending && !parked.doc.isDestroyed && !preview.doc"));
    await evaluate(0, "stress.releaseFresh()");
    await wait(0, `!document.documentElement.hasAttribute('data-${framework}-preview') && document.querySelector('#body-doc') !== preview`);
    await online(0);
    await wait(0, "parked.state === 'closed' && parked.doc.isDestroyed && !parked.hasPending");
    await converge("preview replacement with offline edits and active peers");

    await Promise.all([
      rounds([2, 3], 4, 6),
      ...[0, 1].map(who => (async () => {
        for (let cycle = 0; cycle < 3; cycle++) { await away(who); await editor(who); }
      })()),
    ]);
    await batch([0, 1, 2, 3], 6);
    await converge("two navigating users alongside two continuous writers");

    await evaluate(0, `window.failedCleanup = document.querySelector('#body-doc').session;
      for (const event of ['change', 'update', 'destroy']) failedCleanup.provider.awareness.on(event, () => { throw new Error('expected editor cleanup failure'); });`);
    await Promise.all([away(0), batch([1, 2, 3], 8)]);
    check("throwing awareness callbacks still close the session and cancel its browser timer", await evaluate(0,
      `failedCleanup.state === 'closed' && failedCleanup.doc.isDestroyed && !failedCleanup.hasPending &&
       !stress.intervals.has(failedCleanup.provider.awareness._checkInterval) && String(failedCleanup.error).includes('expected editor cleanup failure')`));
    await editor(0); await batch([0, 1, 2, 3], 6);
    const final = await converge("editing after faulty editor cleanup");
    check("all page visits preserve their framework's JavaScript context", final.every((value, i) => value.context === contexts[i]));
    check("all retired body sessions released documents, queues, and awareness timers", final.every(value => value.retired.every(old => old.state === "closed" && old.destroyed && !old.pending && !old.timerActive)));
    check("browser 1 and 2 each completed at least eight real framework navigations", final.slice(0, 2).every(value => value.navigation.length >= 8));
    const visits = final[0].navigation;
    const overlap = visits.some((event, i) => event.path === "/away" && visits[i + 1] &&
      final.slice(1).some(peer => peer.inputs.some(at => at > event.at && at < visits[i + 1].at)));
    check("actual peer input events occur while another user is on the away page", overlap);
    await browser(0, "screenshot", `${output}/converged.png`);
    await browser(reader, "open", base);
    await wait(reader, "document.querySelector('#body-doc')?.provider?.synced");
    check("a fresh fifth browser reconstructs the exact saved result", await evaluate(reader,
      `document.querySelector('#body-doc').doc.getText('content').toString() === ${JSON.stringify(final[0].text)}`));
    for (let i = 0; i < sessions.length; i++) {
      const errors = await browser(i, "errors");
      check(`browser ${i + 1} has no uncaught errors or unhandled promises`, final[i].errors.length === 0 && (errors.errors ?? []).length === 0);
    }
    await Promise.all(sessions.map((_, i) => away(i)));
    const retired = await Promise.all(sessions.map(snapshot));
    check("leaving all editors releases every tracked body session", retired.every(value => value.retired.every(old => old.state === "closed" && old.destroyed && !old.pending && !old.timerActive)));
    await writeFile(`${output}/result.json`, JSON.stringify({ label, source, checks,
      expectedKeystrokes: expected, totalKeystrokes: expected.reduce((a, b) => a + b, 0), final, typing,
      elapsedMs: Date.now() - started, server: await state() }, null, 2));
    console.log(`PASS ${label}: ${checks.length} checks, ${expected.reduce((a, b) => a + b, 0)} keyboard characters, ${Date.now() - started}ms`);
  } catch (error) {
    const diagnostics = await Promise.allSettled(sessions.map(snapshot));
    await writeFile(`${output}/failure.json`, JSON.stringify({ error: String(error), expected, checks, typing, diagnostics }, null, 2));
    await Promise.allSettled(sessions.map((who, i) => browser(who, "screenshot", `${output}/failure-${i}.png`)));
    throw error;
  } finally {
    for (const who of [...sessions, reader]) await browser(who, "close").catch(() => {});
    server.kill("SIGTERM");
    await new Promise(resolve => {
      if (!server.pid || server.exitCode !== null || server.signalCode !== null) return resolve();
      const timeout = setTimeout(() => { server.kill("SIGKILL"); }, 5000);
      server.once("exit", () => { clearTimeout(timeout); resolve(); });
    });
    await log.close();
  }
}

let port = Number(process.env.PORT || 3793);
for (const framework of frameworks) {
  for (const transport of transports) await run(framework, transport, port++);
}
