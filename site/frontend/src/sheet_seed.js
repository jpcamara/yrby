// What a new agent sheet starts with: an empty "Pre-orders" tab and a
// "Historical" tab of last year's holiday pie orders by channel and month, so
// an ask like "draft a forecast from last year's numbers" has something to
// reference. SheetModel::Canned (app/agents/sheet_model.rb) reads this layout:
// orders in column C, kitchen capacity in C16, gift boxes in stock in C17.
//
// The tab ids are fixed, so two browsers that seed the same new room at once
// write the same tabs and the same cells.

export const TITLE = "Holiday pies"

const HISTORICAL_ROWS = [
  ["Website", "Oct", 3200, 89600],
  ["Website", "Nov", 7900, 221200],
  ["Website", "Dec", 9900, 277200],
  ["Email list", "Oct", 1400, 36400],
  ["Email list", "Nov", 3600, 93600],
  ["Email list", "Dec", 4500, 117000],
  ["Gift boxes", "Oct", 600, 25200],
  ["Gift boxes", "Nov", 2100, 88200],
  ["Gift boxes", "Dec", 3800, 159600],
  ["Grocery partners", "Oct", 2500, 47500],
  ["Grocery partners", "Nov", 4800, 91200],
  ["Grocery partners", "Dec", 5200, 98800],
]

// { A1: { input, format?, bold?, fill? } } for the Historical tab.
export function historicalCells() {
  const cells = {}
  const header = { bold: true, fill: "#ececec" }
  cells.A1 = { input: "Channel", ...header }
  cells.B1 = { input: "Month (2025)", ...header }
  cells.C1 = { input: "Pies ordered", ...header }
  cells.D1 = { input: "Revenue", ...header }
  HISTORICAL_ROWS.forEach(([channel, month, pies, revenue], i) => {
    const row = i + 2
    cells[`A${row}`] = { input: channel }
    cells[`B${row}`] = { input: month }
    cells[`C${row}`] = { input: String(pies), format: "number" }
    cells[`D${row}`] = { input: String(revenue), format: "currency" }
  })
  cells.A15 = { input: "Kitchen and stock", bold: true }
  cells.A16 = { input: "Kitchen capacity (pies per day)" }
  cells.C16 = { input: "1500", format: "number" }
  cells.A17 = { input: "Gift boxes in stock" }
  cells.C17 = { input: "9000", format: "number" }
  return cells
}

export const TABS = [
  { id: "preorders", name: "Pre-orders", cells: () => ({}), widths: { A: 300 } },
  { id: "historical", name: "Historical", cells: historicalCells, widths: { A: 230, B: 120 } },
]
