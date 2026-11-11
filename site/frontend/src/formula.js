// A small spreadsheet formula engine for the agent sheet (sheet.js). Only
// what people type is shared. Each browser computes the values from those
// inputs with this file.
//
// It supports numbers, strings, TRUE and FALSE, + - * / ^ & and the
// comparisons, a postfix %, cell and range references (A1, $B$2, A1:C3, C:C),
// references to other tabs (Historical!A1, 'Last year'!B2:B5), and SUM,
// AVERAGE, MIN, MAX, COUNT, ROUND, ABS, IF, SUMIF, and SUMIFS.
//
// A Workbook computes cells on demand and caches them. Each computed cell
// remembers the cells and ranges it read, so a change to one input clears
// that cell and everything that depends on it, and nothing else. Errors are
// values: #REF!, #DIV/0!, #CIRC!, #VALUE!, #NAME?, and #ERROR! for a formula
// that doesn't parse.

export class SheetError {
  constructor(code) { this.code = code }
  toString() { return this.code }
}

const ERRORS = Object.fromEntries(["#REF!", "#DIV/0!", "#CIRC!", "#VALUE!", "#NAME?", "#ERROR!"].map((c) => [c, new SheetError(c)]))
export const err = (code) => ERRORS[code]
export const isError = (v) => v instanceof SheetError

// --- references --------------------------------------------------------------

export function colIndex(letters) {
  let n = 0
  for (const ch of letters.toUpperCase()) n = n * 26 + (ch.charCodeAt(0) - 64)
  return n - 1
}

export function colName(index) {
  let s = ""
  for (let n = index + 1; n > 0; n = Math.floor((n - 1) / 26)) s = String.fromCharCode(65 + ((n - 1) % 26)) + s
  return s
}

const CELL = /^\$?([A-Za-z]{1,3})\$?([0-9]{1,6})$/

// "B3" -> { col: 1, row: 2 }, or null.
export function parseCell(ref) {
  const m = CELL.exec(ref)
  if (!m) return null
  const row = Number(m[2]) - 1
  return row < 0 ? null : { col: colIndex(m[1]), row }
}

export const cellName = (col, row) => `${colName(col)}${row + 1}`

// --- tokens ------------------------------------------------------------------

// A reference token, with an optional tab: Historical!A1, 'Pre orders'!$B$2:C9,
// C:C. The tab name keeps its quotes off.
const REF = /^(?:(?:'((?:[^']|'')+)'|([A-Za-z_][\w.]*))!)?(\$?[A-Za-z]{1,3}\$?[0-9]{1,6}(?::\$?[A-Za-z]{1,3}\$?[0-9]{1,6})?|\$?[A-Za-z]{1,3}:\$?[A-Za-z]{1,3})(?![\w(!])/

function tokenize(src) {
  const tokens = []
  let i = 0
  while (i < src.length) {
    const rest = src.slice(i)
    const ch = src[i]
    if (/\s/.test(ch)) { i++; continue }
    let m
    if ((m = /^(\d+\.?\d*|\.\d+)(e[+-]?\d+)?/i.exec(rest))) {
      tokens.push({ t: "num", v: Number(m[0]) })
    } else if (ch === '"') {
      m = /^"((?:[^"]|"")*)"/.exec(rest)
      if (!m) throw new SyntaxError("unclosed string")
      tokens.push({ t: "str", v: m[1].replace(/""/g, '"') })
    } else if ((m = REF.exec(rest))) {
      const tab = m[1] !== undefined ? m[1].replace(/''/g, "'") : m[2]
      tokens.push({ t: "ref", tab, ref: m[3].toUpperCase().replace(/\$/g, "") })
    } else if ((m = /^([A-Za-z_][\w.]*)\s*\(/.exec(rest))) {
      tokens.push({ t: "fn", v: m[1].toUpperCase() })
      m = [m[0]]
    } else if ((m = /^(TRUE|FALSE)(?![\w(])/i.exec(rest))) {
      tokens.push({ t: "bool", v: m[1].toUpperCase() === "TRUE" })
    } else if ((m = /^(<>|<=|>=|[-+*/^&=<>%(),:])/.exec(rest))) {
      tokens.push({ t: "op", v: m[1] })
    } else {
      throw new SyntaxError(`unexpected ${ch}`)
    }
    i += m[0].length
  }
  return tokens
}

// --- parser ------------------------------------------------------------------

// Lowest to highest. Each binary operator is left associative except ^.
const BINARY = { "=": 1, "<>": 1, "<": 1, ">": 1, "<=": 1, ">=": 1, "&": 2, "+": 3, "-": 3, "*": 4, "/": 4, "^": 6 }
const UNARY = 7 // tighter than ^, so -2^2 is 4 as in other sheets

export function parse(formula) {
  const tokens = tokenize(formula)
  let pos = 0
  const peek = () => tokens[pos]
  const next = () => tokens[pos++]
  const expectOp = (v) => {
    const tok = next()
    if (tok?.t !== "op" || tok.v !== v) throw new SyntaxError(`expected ${v}`)
  }

  function primary() {
    const tok = next()
    if (!tok) throw new SyntaxError("unexpected end")
    switch (tok.t) {
      case "num": return { k: "num", v: tok.v }
      case "str": return { k: "str", v: tok.v }
      case "bool": return { k: "bool", v: tok.v }
      case "ref": return refNode(tok)
      case "fn": {
        const args = []
        if (!(peek()?.t === "op" && peek().v === ")")) {
          do { args.push(expression(0)) } while (peek()?.t === "op" && peek().v === "," && next())
        }
        expectOp(")")
        return { k: "fn", name: tok.v, args }
      }
      case "op":
        if (tok.v === "(") {
          const inner = expression(0)
          expectOp(")")
          return inner
        }
        if (tok.v === "-" || tok.v === "+") return { k: "neg", sign: tok.v, arg: expression(UNARY) }
    }
    throw new SyntaxError(`unexpected ${tok.v ?? tok.t}`)
  }

  function expression(minPrec) {
    let left = primary()
    for (;;) {
      const tok = peek()
      if (tok?.t !== "op") break
      if (tok.v === "%") { next(); left = { k: "pct", arg: left }; continue }
      const prec = BINARY[tok.v]
      if (prec === undefined || prec < minPrec) break
      next()
      left = { k: "bin", op: tok.v, left, right: expression(tok.v === "^" ? prec : prec + 1) }
    }
    return left
  }

  const tree = expression(0)
  if (pos < tokens.length) throw new SyntaxError(`unexpected ${tokens[pos].v ?? tokens[pos].t}`)
  return tree
}

function refNode({ tab, ref }) {
  const [a, b] = ref.split(":")
  if (b === undefined) return { k: "cell", tab, ...parseCell(a) }
  const whole = !/\d/.test(a)
  if (whole) return { k: "range", tab, c1: colIndex(a), c2: colIndex(b), r1: 0, r2: null }
  const p = parseCell(a)
  const q = parseCell(b)
  return {
    k: "range", tab,
    c1: Math.min(p.col, q.col), c2: Math.max(p.col, q.col),
    r1: Math.min(p.row, q.row), r2: Math.max(p.row, q.row),
  }
}

// --- values ------------------------------------------------------------------

// What a typed input means when it isn't a formula: a number (commas, a
// leading $ and a trailing % allowed), TRUE/FALSE, empty, or text.
export function literal(input) {
  const s = String(input ?? "").trim()
  if (s === "") return null
  const m = /^([-+]?)\$?(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d*\.?\d+(?:e[+-]?\d+)?)(%?)$/i.exec(s)
  if (m) {
    const n = Number(m[2].replace(/,/g, "")) * (m[1] === "-" ? -1 : 1)
    return m[3] ? n / 100 : n
  }
  if (/^(true|false)$/i.test(s)) return s.toLowerCase() === "true"
  return String(input)
}

function toNumber(v) {
  if (isError(v)) return v
  if (v === null || v === undefined || v === "") return 0
  if (typeof v === "number") return v
  if (typeof v === "boolean") return v ? 1 : 0
  const n = literal(v)
  return typeof n === "number" ? n : err("#VALUE!")
}

const toText = (v) => (v === null || v === undefined ? "" : typeof v === "boolean" ? (v ? "TRUE" : "FALSE") : String(v))

function compare(a, b) {
  a ??= typeof b === "string" ? "" : 0
  b ??= typeof a === "string" ? "" : 0
  if (typeof a === "string" && typeof b === "string") {
    const x = a.toLowerCase()
    const y = b.toLowerCase()
    return x < y ? -1 : x > y ? 1 : 0
  }
  if (typeof a === "string") return 1 // text sorts after numbers, as in other sheets
  if (typeof b === "string") return -1
  return Number(a) - Number(b)
}

// A SUMIF criterion: ">100", "<>Email", "=Website", or a plain value that
// must match.
function criterion(spec) {
  if (isError(spec)) return () => false
  let op = "="
  let rhs = spec
  if (typeof spec === "string") {
    const m = /^(<>|<=|>=|=|<|>)(.*)$/s.exec(spec)
    if (m) {
      op = m[1]
      rhs = m[2]
    }
    const n = literal(rhs)
    rhs = typeof n === "number" || typeof n === "boolean" ? n : rhs
  }
  return (v) => {
    if (isError(v)) return false
    if (typeof rhs === "number" && typeof v !== "number") {
      const n = literal(v)
      if (typeof n !== "number") return op === "<>"
      v = n
    }
    const c = compare(v, rhs)
    return { "=": c === 0, "<>": c !== 0, "<": c < 0, ">": c > 0, "<=": c <= 0, ">=": c >= 0 }[op]
  }
}

// --- the workbook ------------------------------------------------------------

// `source` reads the shared inputs:
//
//   tabs()               [{ id, name }] in order
//   input(tabId, ref)    what was typed in the cell, or undefined
//   extent(tabId)        { rows, cols }, how far the tab's inputs reach
//
// A tab name in a formula matches case-insensitively. A formula with no tab
// reads its own tab.
export class Workbook {
  constructor(source) {
    this.source = source
    this.values = new Map() // "tabId!A1" -> value
    this.reads = new Map() // key -> { cells: Set(key), ranges: [{ tab, c1, c2, r1, r2 }] }
    this.parsed = new Map() // formula text -> tree or SheetError
    this.evaluating = new Set()
  }

  // The value of a cell: a number, string, boolean, SheetError, or null when
  // it's empty.
  value(tabId, ref) {
    const key = `${tabId}!${ref}`
    if (this.values.has(key)) return this.values.get(key)
    if (this.evaluating.has(key)) return err("#CIRC!")

    const input = this.source.input(tabId, ref)
    if (typeof input !== "string" || !input.startsWith("=")) {
      const v = literal(input)
      this.values.set(key, v)
      return v
    }

    this.evaluating.add(key)
    const reads = { cells: new Set(), ranges: [] }
    let v
    try {
      const tree = this.tree(input.slice(1))
      v = isError(tree) ? tree : this.evaluate(tree, tabId, reads)
      if (Array.isArray(v)) v = v.length === 1 && v[0].length === 1 ? v[0][0] : err("#VALUE!")
      if (typeof v === "number" && !Number.isFinite(v)) v = err("#DIV/0!")
    } finally {
      this.evaluating.delete(key)
    }
    // A cycle shows #CIRC! on every cell in it. Each of them read the next,
    // so changing any input in the cycle clears all of them.
    this.values.set(key, v)
    this.reads.set(key, reads)
    return v
  }

  tree(formula) {
    if (!this.parsed.has(formula)) {
      let tree
      try { tree = parse(formula) } catch { tree = err("#ERROR!") }
      this.parsed.set(formula, tree)
    }
    return this.parsed.get(formula)
  }

  // Forget a cell and everything that read it, after its input changed.
  invalidate(tabId, ref) {
    const pos = parseCell(ref)
    const queue = [`${tabId}!${ref}`]
    const seen = new Set()
    while (queue.length) {
      const key = queue.pop()
      if (seen.has(key)) continue
      seen.add(key)
      this.values.delete(key)
      this.reads.delete(key)
      const [tab, cell] = splitKey(key)
      const p = tab === tabId && cell === ref ? pos : parseCell(cell)
      for (const [other, reads] of this.reads) {
        if (seen.has(other)) continue
        if (reads.cells.has(key) || reads.ranges.some((r) => r.tab === tab && covers(r, p))) {
          queue.push(other)
        }
      }
    }
  }

  // Forget everything, such as after a tab is renamed or deleted.
  invalidateAll() {
    this.values.clear()
    this.reads.clear()
  }

  tabId(name, from) {
    if (name === undefined) return from
    const lower = name.toLowerCase()
    return this.source.tabs().find((t) => t.name.toLowerCase() === lower)?.id
  }

  evaluate(node, tabId, reads) {
    switch (node.k) {
      case "num": case "str": case "bool": return node.v
      case "cell": {
        const tab = this.tabId(node.tab, tabId)
        if (tab === undefined) return err("#REF!")
        const ref = cellName(node.col, node.row)
        reads.cells.add(`${tab}!${ref}`)
        return this.value(tab, ref)
      }
      case "range": return this.range(node, tabId, reads)
      case "neg": {
        const n = toNumber(scalar(this.evaluate(node.arg, tabId, reads)))
        return isError(n) ? n : node.sign === "-" ? -n : n
      }
      case "pct": {
        const n = toNumber(scalar(this.evaluate(node.arg, tabId, reads)))
        return isError(n) ? n : n / 100
      }
      case "bin": return binary(node.op, scalar(this.evaluate(node.left, tabId, reads)), scalar(this.evaluate(node.right, tabId, reads)))
      case "fn": return this.call(node, tabId, reads)
    }
    return err("#ERROR!")
  }

  // A range as rows of values. A whole column (C:C) stops at the last row
  // that has an input.
  range(node, tabId, reads) {
    const tab = this.tabId(node.tab, tabId)
    if (tab === undefined) return err("#REF!")
    const r2 = node.r2 ?? Math.max(0, this.source.extent(tab).rows - 1)
    reads.ranges.push({ tab, c1: node.c1, c2: node.c2, r1: node.r1, r2: node.r2 })
    const rows = []
    for (let r = node.r1; r <= r2; r++) {
      const row = []
      for (let c = node.c1; c <= node.c2; c++) row.push(this.value(tab, cellName(c, r)))
      rows.push(row)
    }
    return rows
  }

  call({ name, args }, tabId, reads) {
    const fn = FUNCTIONS[name]
    if (!fn) return err("#NAME?")
    // IF only computes the branch it takes.
    if (name === "IF") {
      if (args.length < 2 || args.length > 3) return err("#VALUE!")
      const test = scalar(this.evaluate(args[0], tabId, reads))
      if (isError(test)) return test
      const truthy = typeof test === "string" ? test !== "" : Boolean(test)
      if (truthy) return scalar(this.evaluate(args[1], tabId, reads))
      return args.length === 3 ? scalar(this.evaluate(args[2], tabId, reads)) : false
    }
    return fn(args.map((a) => this.evaluate(a, tabId, reads)))
  }
}

function splitKey(key) {
  const at = key.lastIndexOf("!")
  return [key.slice(0, at), key.slice(at + 1)]
}

// Whether range `r` reads position `p`. A whole-column range reads every row.
function covers(r, p) {
  if (!p) return false
  return p.col >= r.c1 && p.col <= r.c2 && p.row >= r.r1 && (r.r2 === null || p.row <= r.r2)
}

// A range used where one value belongs.
function scalar(v) {
  if (!Array.isArray(v)) return v
  return v.length === 1 && v[0].length === 1 ? v[0][0] : err("#VALUE!")
}

function binary(op, a, b) {
  if (isError(a)) return a
  if (isError(b)) return b
  if (op === "&") return toText(a) + toText(b)
  if (BINARY[op] === 1) {
    const c = compare(a, b)
    return { "=": c === 0, "<>": c !== 0, "<": c < 0, ">": c > 0, "<=": c <= 0, ">=": c >= 0 }[op]
  }
  const x = toNumber(a)
  const y = toNumber(b)
  if (isError(x)) return x
  if (isError(y)) return y
  switch (op) {
    case "+": return x + y
    case "-": return x - y
    case "*": return x * y
    case "/": return y === 0 ? err("#DIV/0!") : x / y
    case "^": return x ** y
  }
  return err("#ERROR!")
}

// --- functions ---------------------------------------------------------------

// The numbers among a function's arguments. Inside a range, text and blanks
// are skipped. A number typed as an argument counts, and text that isn't a
// number there is #VALUE!.
function numbers(args) {
  const out = []
  for (const arg of args) {
    if (Array.isArray(arg)) {
      for (const row of arg) {
        for (const v of row) {
          if (isError(v)) return v
          if (typeof v === "number") out.push(v)
        }
      }
    } else {
      if (isError(arg)) return arg
      if (arg === null) continue
      const n = toNumber(arg)
      if (isError(n)) return n
      out.push(n)
    }
  }
  return out
}

const flat = (v) => (Array.isArray(v) ? v.flat() : [v])

function sumIfs(sumRange, pairs) {
  if (!Array.isArray(sumRange)) return err("#VALUE!")
  const values = sumRange.flat()
  const tests = []
  for (const [range, spec] of pairs) {
    const cells = flat(range)
    if (cells.length !== values.length) return err("#VALUE!")
    tests.push([cells, criterion(scalar(spec))])
  }
  let total = 0
  values.forEach((v, i) => {
    if (typeof v === "number" && tests.every(([cells, test]) => test(cells[i]))) total += v
  })
  return total
}

const FUNCTIONS = {
  SUM: (args) => { const n = numbers(args); return isError(n) ? n : n.reduce((a, b) => a + b, 0) },
  AVERAGE: (args) => {
    const n = numbers(args)
    if (isError(n)) return n
    return n.length ? n.reduce((a, b) => a + b, 0) / n.length : err("#DIV/0!")
  },
  MIN: (args) => { const n = numbers(args); return isError(n) ? n : n.length ? Math.min(...n) : 0 },
  MAX: (args) => { const n = numbers(args); return isError(n) ? n : n.length ? Math.max(...n) : 0 },
  COUNT: (args) => args.flatMap(flat).filter((v) => typeof v === "number").length,
  ABS: (args) => {
    if (args.length !== 1) return err("#VALUE!")
    const n = toNumber(scalar(args[0]))
    return isError(n) ? n : Math.abs(n)
  },
  ROUND: (args) => {
    if (args.length < 1 || args.length > 2) return err("#VALUE!")
    const n = toNumber(scalar(args[0]))
    const d = args.length > 1 ? toNumber(scalar(args[1])) : 0
    if (isError(n)) return n
    if (isError(d)) return d
    const f = 10 ** Math.trunc(d)
    return Math.sign(n) * Math.round(Math.abs(n) * f + 1e-9) / f
  },
  IF: () => err("#VALUE!"), // evaluated lazily in Workbook#call
  SUMIF: (args) => {
    if (args.length < 2 || args.length > 3) return err("#VALUE!")
    return sumIfs(args.length === 3 ? args[2] : args[0], [[args[0], args[1]]])
  },
  SUMIFS: (args) => {
    if (args.length < 3 || args.length % 2 === 0) return err("#VALUE!")
    const pairs = []
    for (let i = 1; i < args.length; i += 2) pairs.push([args[i], args[i + 1]])
    return sumIfs(args[0], pairs)
  },
}

export const FUNCTION_NAMES = Object.keys(FUNCTIONS)

// --- display -----------------------------------------------------------------

// How a value shows in its cell, in one of the formats: number (21,000),
// percent (10%), currency ($21,000), or text (as typed). Numbers with no
// format show up to two decimals.
export function display(value, format) {
  if (value === null || value === undefined) return ""
  if (isError(value)) return value.code
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE"
  if (typeof value !== "number" || format === "text") return String(value)
  const fixed = (n, digits) => n.toLocaleString("en-US", { maximumFractionDigits: digits, minimumFractionDigits: 0 })
  switch (format) {
    case "percent": return `${fixed(value * 100, 1)}%`
    case "currency": return `${value < 0 ? "-" : ""}$${fixed(Math.abs(value), 2)}`
    case "number": return fixed(value, 0)
    default: return fixed(value, 2)
  }
}

// Rewrites tab references in a formula after a tab is renamed, so
// =SUM(Historical!B2:B5) follows Historical to its new name. Text inside
// strings is left alone.
export function renameTab(input, from, to) {
  if (typeof input !== "string" || !input.startsWith("=")) return input
  const quoted = (name) => (/^[A-Za-z_][\w.]*$/.test(name) ? name : `'${name.replace(/'/g, "''")}'`)
  const lower = from.toLowerCase()
  let out = ""
  let i = 0
  const src = input
  while (i < src.length) {
    if (src[i] === '"') {
      const end = src.indexOf('"', i + 1)
      const stop = end === -1 ? src.length : end + 1
      out += src.slice(i, stop)
      i = stop
      continue
    }
    const m = /^(?:'((?:[^']|'')+)'|([A-Za-z_][\w.]*))!/.exec(src.slice(i))
    const before = src[i - 1]
    if (m && !(before && /[\w.']/.test(before))) {
      const name = m[1] !== undefined ? m[1].replace(/''/g, "'") : m[2]
      out += name.toLowerCase() === lower ? `${quoted(to)}!` : m[0]
      i += m[0].length
      continue
    }
    out += src[i]
    i++
  }
  return out
}
