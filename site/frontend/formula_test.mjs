// node --test formula_test.mjs
// The agent sheet's formula engine (src/formula.js), against plain objects
// instead of a Y.Doc.
import { test } from "node:test"
import assert from "node:assert/strict"
import { Workbook, display, isError, literal, parse, renameTab, colName, colIndex } from "./src/formula.js"
import { parseCell } from "./src/formula.js"

// A workbook over { tabName: { A1: input } }. Tab ids are the lowercased
// names, so formulas name tabs the way people see them.
function book(tabs) {
  const data = Object.fromEntries(Object.entries(tabs).map(([name, cells]) => [name.toLowerCase(), { name, cells }]))
  const source = {
    tabs: () => Object.entries(data).map(([id, { name }]) => ({ id, name })),
    input: (tab, ref) => data[tab]?.cells[ref],
    extent: (tab) => {
      let rows = 0
      let cols = 0
      for (const ref of Object.keys(data[tab]?.cells ?? {})) {
        const p = parseCell(ref)
        rows = Math.max(rows, p.row + 1)
        cols = Math.max(cols, p.col + 1)
      }
      return { rows, cols }
    },
  }
  const wb = new Workbook(source)
  return {
    wb,
    get: (ref, tab = Object.keys(data)[0]) => wb.value(tab, ref),
    set(ref, input, tab = Object.keys(data)[0]) {
      data[tab].cells[ref] = input
      wb.invalidate(tab, ref)
    },
    rename(id, name) { data[id].name = name; wb.invalidateAll() },
  }
}

const code = (v) => (isError(v) ? v.code : v)

test("column letters and cell names", () => {
  assert.deepEqual([0, 25, 26, 27, 701, 702].map(colName), ["A", "Z", "AA", "AB", "ZZ", "AAA"])
  assert.equal(colIndex("AB"), 27)
  assert.deepEqual(parseCell("$C$10"), { col: 2, row: 9 })
  assert.equal(parseCell("A0"), null)
})

test("typed values", () => {
  assert.equal(literal("21,000"), 21000)
  assert.equal(literal("-1.5"), -1.5)
  assert.equal(literal("10%"), 0.1)
  assert.equal(literal("$1,250.50"), 1250.5)
  assert.equal(literal("TRUE"), true)
  assert.equal(literal(""), null)
  assert.equal(literal("1,2"), "1,2")
  assert.equal(literal("Website"), "Website")
})

test("arithmetic follows precedence", () => {
  const { get } = book({ S: { A1: "=1+2*3", A2: "=(1+2)*3", A3: "=2^3^2", A4: "=-2^2", A5: "=10%*50", A6: "=7/2", A7: "=\"a\"&1&TRUE" } })
  assert.equal(get("A1"), 7)
  assert.equal(get("A2"), 9)
  assert.equal(get("A3"), 512)
  assert.equal(get("A4"), 4) // unary minus binds tighter, as in other sheets
  assert.equal(get("A5"), 5)
  assert.equal(get("A6"), 3.5)
  assert.equal(get("A7"), "a1TRUE")
})

test("comparisons", () => {
  const { get } = book({ S: { A1: "=1<2", A2: "=\"abc\"=\"ABC\"", A3: "=3<>3", A4: "=B9=0", A5: "=2>=2" } })
  assert.deepEqual(["A1", "A2", "A3", "A4", "A5"].map((r) => get(r)), [true, true, false, true, true])
})

test("cell and absolute references", () => {
  const { get } = book({ S: { A1: "21000", B1: "=A1*1.1", C1: "=$B$1-A1", D1: "=E1+1" } })
  assert.ok(Math.abs(get("B1") - 23100) < 1e-6)
  assert.ok(Math.abs(get("C1") - 2100) < 1e-6)
  assert.equal(get("D1"), 1) // empty is 0
})

test("ranges and the aggregate functions", () => {
  const { get } = book({
    S: {
      A1: "1", A2: "2", A3: "3", A4: "text", A5: "",
      B1: "=SUM(A1:A5)", B2: "=AVERAGE(A1:A5)", B3: "=MIN(A1:A3, -4)", B4: "=MAX(A:A)", B5: "=COUNT(A1:A5)",
      B6: "=ROUND(2/3, 2)", B7: "=ROUND(-2.5)", B8: "=SUM(A1, 10)", B9: "=AVERAGE(C1:C3)", B10: "=ABS(-3)",
    },
  })
  assert.equal(get("B1"), 6)
  assert.equal(get("B2"), 2)
  assert.equal(get("B3"), -4)
  assert.equal(get("B4"), 3)
  assert.equal(get("B5"), 3)
  assert.equal(get("B6"), 0.67)
  assert.equal(get("B7"), -3)
  assert.equal(get("B8"), 11)
  assert.equal(code(get("B9")), "#DIV/0!")
  assert.equal(get("B10"), 3)
})

test("IF takes only its branch", () => {
  const { get } = book({ S: { A1: "5", B1: "=IF(A1>3, \"big\", 1/0)", B2: "=IF(A1>9, 1/0, \"small\")", B3: "=IF(0, 1)" } })
  assert.equal(get("B1"), "big")
  assert.equal(get("B2"), "small")
  assert.equal(get("B3"), false)
})

test("SUMIF and SUMIFS, across tabs and whole columns", () => {
  const historical = {
    A1: "Channel", B1: "Month", C1: "Orders",
    A2: "Website", B2: "Oct", C2: "1200",
    A3: "Email list", B3: "Oct", C3: "800",
    A4: "Website", B4: "Nov", C4: "3,400",
    A5: "Website", B5: "Dec", C5: "5100",
    A6: "Email list", B6: "Dec", C6: "2000",
  }
  const { get } = book({
    "Pre-orders": {
      A2: "Website",
      B2: "=SUMIFS(Historical!C:C, Historical!A:A, A2)",
      B3: "=SUMIFS(Historical!C:C, Historical!A:A, A2, Historical!B:B, \"<>Oct\")",
      B4: "=SUMIF(Historical!C2:C6, \">1000\")",
      B5: "=SUMIF(Historical!A2:A6, \"email list\", Historical!C2:C6)",
      B6: "=SUMIFS(Historical!C2:C6, Historical!A2:A5, A2)",
    },
    Historical: historical,
  })
  assert.equal(get("B2"), 9700)
  assert.equal(get("B3"), 8500)
  assert.equal(get("B4"), 11700)
  assert.equal(get("B5"), 2800)
  assert.equal(code(get("B6")), "#VALUE!") // ranges of different sizes
})

test("quoted tab names", () => {
  const { get } = book({ S: { A1: "='Last year'!A1*2" }, "Last year": { A1: "4" } })
  assert.equal(get("A1"), 8)
})

test("errors: #REF!, #DIV/0!, #CIRC!, #NAME?, #ERROR!, #VALUE!", () => {
  const { get } = book({
    S: {
      A1: "=Nope!A1", A2: "=1/0", A3: "=A4", A4: "=A3", A5: "=A3+1", A6: "=FOO(1)", A7: "=1+", A8: "=\"x\"*2", A9: "=A2+1",
      B1: "=B1",
    },
  })
  assert.equal(code(get("A1")), "#REF!")
  assert.equal(code(get("A2")), "#DIV/0!")
  assert.equal(code(get("A3")), "#CIRC!")
  assert.equal(code(get("A4")), "#CIRC!")
  assert.equal(code(get("A5")), "#CIRC!")
  assert.equal(code(get("A6")), "#NAME?")
  assert.equal(code(get("A7")), "#ERROR!")
  assert.equal(code(get("A8")), "#VALUE!")
  assert.equal(code(get("A9")), "#DIV/0!") // errors carry through
  assert.equal(code(get("B1")), "#CIRC!")
})

test("a change recalculates what depends on it, and nothing else", () => {
  const b = book({ S: { A1: "2", A2: "=A1*10", A3: "=SUM(A1:A2)", B1: "=7", C1: "=SUM(A:A)" } })
  assert.equal(b.get("A3"), 22)
  assert.equal(b.get("C1"), 44)
  b.get("B1")
  b.set("A1", "3")
  assert.equal(b.wb.values.has("s!B1"), true) // untouched
  assert.equal(b.wb.values.has("s!A3"), false)
  assert.equal(b.get("A3"), 33)
  assert.equal(b.get("C1"), 66)
  // A new row inside a whole-column range counts.
  b.set("A9", "100")
  assert.equal(b.get("C1"), 166)
})

test("breaking a cycle clears it", () => {
  const b = book({ S: { A1: "=A2", A2: "=A1" } })
  assert.equal(code(b.get("A1")), "#CIRC!")
  b.set("A2", "4")
  assert.equal(b.get("A1"), 4)
})

test("renaming a tab follows its references, and leaves strings alone", () => {
  assert.equal(renameTab("=SUM(Historical!C:C)+Historical!A1", "Historical", "Last year"),
    "=SUM('Last year'!C:C)+'Last year'!A1")
  assert.equal(renameTab("=\"Historical!A1\"&Other!A1", "Historical", "X"), "=\"Historical!A1\"&Other!A1")
  assert.equal(renameTab("='Pre orders'!B2", "pre orders", "Orders"), "=Orders!B2")
  assert.equal(renameTab("21000", "Historical", "X"), "21000")

  const b = book({ S: { A1: "=Old!A1" }, Old: { A1: "5" } })
  assert.equal(b.get("A1"), 5)
  b.rename("old", "New")
  assert.equal(code(b.get("A1")), "#REF!")
})

test("display formats", () => {
  assert.equal(display(21000, "number"), "21,000")
  assert.equal(display(0.1, "percent"), "10%")
  assert.equal(display(0.125, "percent"), "12.5%")
  assert.equal(display(-1250.5, "currency"), "-$1,250.5")
  assert.equal(display(2 / 3), "0.67")
  assert.equal(display("Website", "number"), "Website")
  assert.equal(display(null), "")
  assert.equal(display(4200, "+number"), "+4,200")
  assert.equal(display(-10000, "+number"), "-10,000")
  assert.equal(display(0.1, "+percent"), "+10%")
  assert.equal(display(0, "+percent"), "0%")
  assert.equal(display(0.0001, "+number"), "0")
})

test("parse rejects junk", () => {
  assert.throws(() => parse("1 2"))
  assert.throws(() => parse("SUM(1"))
  assert.throws(() => parse("#"))
})
