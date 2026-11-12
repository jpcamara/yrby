// Random concurrent Yjs editing, shared by the convergence and concurrency
// tests: a seeded PRNG, one random edit, peer sync, and state comparison.
import * as Y from 'yjs'

export function rng (seed) {
  const rand = () => {
    seed = (seed * 1664525 + 1013904223) >>> 0
    return seed / 2 ** 32
  }
  const pick = (xs) => xs[Math.floor(rand() * xs.length)]
  const shuffle = (xs) => {
    const a = xs.slice()
    for (let i = a.length - 1; i > 0; i--) {
      const j = Math.floor(rand() * (i + 1));
      [a[i], a[j]] = [a[j], a[i]]
    }
    return a
  }
  return { rand, pick, shuffle }
}

const CHUNKS = ['a', 'bc', 'héllo', '👋', '日本', ' ', 'x👍🏽y', '\n']

// One random edit: text with UTF-16 surrogate pairs, map sets, array pushes
// and deletes.
export function edit (doc, { rand, pick }) {
  const text = doc.getText('body')
  const meta = doc.getMap('meta')
  const list = doc.getArray('list')
  const r = rand()
  doc.transact(() => {
    if (r < 0.55) {
      // Insert at a UTF-16 index that does not split a surrogate pair.
      const s = text.toString()
      let at = Math.floor(rand() * (s.length + 1))
      if (at > 0 && at < s.length && /[\uDC00-\uDFFF]/.test(s[at])) at--
      text.insert(at, pick(CHUNKS))
    } else if (r < 0.75 && text.length > 0) {
      const s = text.toString()
      let at = Math.floor(rand() * s.length)
      if (/[\uDC00-\uDFFF]/.test(s[at])) at--
      let len = 1 + Math.floor(rand() * 3)
      if (at + len < s.length && /[\uDC00-\uDFFF]/.test(s[at + len])) len++
      text.delete(at, Math.min(len, s.length - at))
    } else if (r < 0.88) {
      meta.set(pick(['title', 'owner', 'n']), pick(['A', 'B', 1, 2.5, true, null, { k: [1, 'z'] }]))
    } else if (r < 0.96 || list.length === 0) {
      list.push([pick([1, 'two', { three: 3 }])])
    } else {
      list.delete(Math.floor(rand() * list.length), 1)
    }
  })
}

export function sync (a, b) {
  Y.applyUpdate(b, Y.encodeStateAsUpdate(a, Y.encodeStateVector(b)), 'remote')
  Y.applyUpdate(a, Y.encodeStateAsUpdate(b, Y.encodeStateVector(a)), 'remote')
}

// PEERS docs edit for STEPS steps with partial syncs, then fully sync.
// Returns every local update and the converged JS state. onStep(s, updates)
// runs after each step.
export function session (r, peerCount, steps, onStep = () => {}) {
  const peers = Array.from({ length: peerCount }, () => new Y.Doc())
  const updates = []
  for (const p of peers) {
    p.on('update', (u, origin) => { if (origin !== 'remote') updates.push(u) })
  }
  for (let s = 0; s < steps; s++) {
    edit(r.pick(peers), r)
    if (r.rand() < 0.25) {
      const [a, b] = r.shuffle(peers)
      sync(a, b)
    }
    onStep(s, updates)
  }
  for (const a of peers) for (const b of peers) if (a !== b) sync(a, b)
  const expected = snapshotOf(peers[0])
  for (const p of peers) {
    if (canon(snapshotOf(p)) !== canon(expected)) throw new Error('JS peers did not converge')
  }
  return { peers, updates, expected }
}

export const snapshotOf = (doc) => ({
  body: doc.getText('body').toString(),
  meta: doc.getMap('meta').toJSON(),
  list: doc.getArray('list').toJSON()
})
export const docFrom = (bytes) => {
  const d = new Y.Doc()
  Y.applyUpdate(d, bytes)
  return d
}
export const canon = (v) => JSON.stringify(v, (_, x) =>
  x && typeof x === 'object' && !Array.isArray(x) ? Object.fromEntries(Object.entries(x).sort()) : x)
export const svMap = (bytes) => canon(Object.fromEntries([...Y.decodeStateVector(bytes)].sort()))
