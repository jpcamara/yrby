// What a new agent sheet starts with: an empty "Pre-orders" tab and a
// "Historical" tab of last year's holiday pie orders by channel and month, so
// an ask like "draft a forecast from last year's numbers" has something to
// reference. SheetModel::Canned (app/agents/sheet_model.rb) reads this layout:
// orders in column C, the full line's capacity in C16, pie boxes in stock in C17.
//
// The tab ids are fixed, so two browsers that seed the same new room at once
// write the same tabs and the same cells.

export const TITLE = "Holiday Pie: Pre-orders"

const HISTORICAL_ROWS = [
  ["Website", "Oct", 3200, 89600],
  ["Website", "Nov", 7900, 221200],
  ["Website", "Dec", 9900, 277200],
  ["Email list", "Oct", 2000, 52000],
  ["Email list", "Nov", 5000, 130000],
  ["Email list", "Dec", 7000, 182000],
  ["Gift boxes", "Oct", 1000, 42000],
  ["Gift boxes", "Nov", 3000, 126000],
  ["Gift boxes", "Dec", 5000, 210000],
  ["Grocery partners", "Oct", 1500, 28500],
  ["Grocery partners", "Nov", 2000, 38000],
  ["Grocery partners", "Dec", 2500, 47500],
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
  cells.A16 = { input: "Full line capacity (pies per day)" }
  cells.C16 = { input: "10000", format: "number" }
  cells.A17 = { input: "Pie boxes in stock" }
  cells.C17 = { input: "65000", format: "number" }
  return cells
}

export const TABS = [
  { id: "preorders", name: "Pre-orders", cells: () => ({}), widths: { A: 300 } },
  { id: "historical", name: "Historical", cells: historicalCells, widths: { A: 230, B: 120 } },
]
