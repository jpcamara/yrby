// Dump and restore: ydoc values must come back byte for byte through
// pg_dump (plain and custom format, which use text COPY) and binary COPY
// (which uses ydoc_send/ydoc_recv). Binary input must also reject bytes that
// are not a v1 update, as text input does.
//
// Creates and drops databases pg_yrby_dump_* on the test server.
// Usage: node dump.mjs   Env: PGPORT (28817), PGBIN (Homebrew postgresql@17)
import pg from 'pg'
import * as Y from 'yjs'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { rng, session } from './session.mjs'

const PORT = String(process.env.PGPORT ?? 28817)
const BIN = process.env.PGBIN ?? '/opt/homebrew/opt/postgresql@17/bin'
const conn = ['-h', 'localhost', '-p', PORT]
const run = (tool, ...args) => execFileSync(path.join(BIN, tool), [...conn, ...args], { stdio: ['ignore', 'pipe', 'pipe'] }).toString()
const psql = (db, ...args) => run('psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', db, ...args)
const DBS = ['src', 'plain', 'custom', 'bin'].map((n) => `pg_yrby_dump_${n}`)
const [SRC, PLAIN, CUSTOM, BINARY] = DBS
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pg_yrby_dump-'))

for (const db of DBS) run('dropdb', '--if-exists', db)
for (const db of DBS) run('createdb', db)

// Documents of every shape: empty, NULL, text, map/array/XML, pending
// (an update whose dependency never arrived), a large one that TOAST stores
// out of line, and a long random session.
const encode = (fill) => {
  const d = new Y.Doc()
  fill(d)
  return Buffer.from(Y.encodeStateAsUpdate(d))
}
const r = rng(7)
const big = Array.from({ length: 200000 }, () => String.fromCharCode(0x20 + Math.floor(r.rand() * 0x5e))).join('')
const gapped = (() => {
  const d = new Y.Doc()
  const parts = []
  d.on('update', (u) => parts.push(u))
  d.getText('body').insert(0, 'first')
  d.getText('body').insert(5, ' second')
  return Buffer.from(parts[1])
})()
const sess = session(r, 4, 300)
const docs = [
  [1, 'empty', null, 'ydoc()'],
  [2, 'null', null, 'null'],
  [3, 'text', encode((d) => d.getText('body').insert(0, 'héllo 👋🏽 日本\n')), null],
  [4, 'shapes', encode((d) => {
    d.getMap('meta').set('title', 'T')
    d.getMap('meta').set('nested', { k: [1, 'z'] })
    d.getArray('list').push([1, 'two', { three: 3 }])
    const p = new Y.XmlElement('para')
    p.insert(0, [new Y.XmlText('xml text')])
    d.getXmlFragment('xml').insert(0, [p])
  }), null],
  [5, 'pending', gapped, null],
  [6, 'large', encode((d) => d.getText('body').insert(0, big)), null],
  [7, 'session', Buffer.from(Y.mergeUpdates(sess.updates)), null]
]

const src = new pg.Client({ host: 'localhost', port: Number(PORT), database: SRC })
await src.connect()
await src.query('create extension pg_yrby')
await src.query('create table docs (id int primary key, name text, body ydoc)')
for (const [id, name, bytes, sql] of docs) {
  if (bytes) await src.query('insert into docs values ($1, $2, ydoc_apply(null, $3))', [id, name, bytes])
  else await src.query(`insert into docs values ($1, $2, ${sql})`, [id, name])
}
await src.end()

// Everything that should survive, per row.
const FINGERPRINT = `
  select id, name, md5(body::bytea) h, ydoc_has_pending(body) p, ydoc_json(body)::text j,
         ydoc_xml(body, 'xml') x, pg_column_size(body) > 100000 as big
    from docs order by id`
const fingerprint = (db) => psql(db, '-A', '-t', '-c', FINGERPRINT)

const results = {}
const want = fingerprint(SRC)
const rows = want.trim().split('\n')
if (rows.length !== docs.length || !rows.some((l) => l.endsWith('|t')) || !rows.some((l) => l.includes('|pending|') && l.includes('|t|'))) {
  throw new Error(`unexpected source rows:\n${want}`)
}
const check = (name, db) => { results[name] = fingerprint(db) === want }

// pg_dump plain, restored with psql.
fs.writeFileSync(path.join(tmp, 'plain.sql'), run('pg_dump', '-d', SRC))
psql(PLAIN, '-f', path.join(tmp, 'plain.sql'))
check('pg_dump plain', PLAIN)

// pg_dump custom format, restored with pg_restore.
run('pg_dump', '-Fc', '-d', SRC, '-f', path.join(tmp, 'custom.dump'))
run('pg_restore', '-d', CUSTOM, path.join(tmp, 'custom.dump'))
check('pg_dump custom', CUSTOM)

// Binary COPY out and back in.
const binFile = path.join(tmp, 'docs.bin')
psql(SRC, '-c', `\\copy docs to '${binFile}' with (format binary)`)
psql(BINARY, '-c', 'create extension pg_yrby', '-c', 'create table docs (id int primary key, name text, body ydoc)')
psql(BINARY, '-c', `\\copy docs from '${binFile}' with (format binary)`)
check('binary copy', BINARY)

// Binary COPY of bytes that are not an update must fail, like text input.
const rejects = (label, hex) => {
  const f = path.join(tmp, `bad-${label}.bin`)
  psql(SRC, '-c', `\\copy (select 99, 'bad', '\\x${hex}'::bytea) to '${f}' with (format binary)`)
  try {
    psql(BINARY, '-c', `\\copy docs from '${f}' with (format binary)`)
    return false
  } catch (e) {
    return /pg_yrby/.test(e.stderr.toString())
  }
}
results['binary rejects garbage'] = rejects('garbage', 'deadbeef')
results['binary rejects truncated'] = rejects('truncated', docs[2][2].subarray(0, docs[2][2].length - 3).toString('hex'))

for (const db of DBS) run('dropdb', '--if-exists', db)
fs.rmSync(tmp, { recursive: true, force: true })

const bad = Object.entries(results).filter(([, ok]) => !ok).map(([k]) => k)
for (const [k, ok] of Object.entries(results)) console.log(`${ok ? 'ok  ' : 'FAIL'} ${k}`)
console.log(`${Object.keys(results).length - bad.length}/${Object.keys(results).length} dump checks passed`)
process.exit(bad.length ? 1 : 0)
