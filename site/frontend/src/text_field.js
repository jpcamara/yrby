// Binds an <input> or <textarea> to a Y.Text, so two people typing in the
// same field merge character by character instead of the last one winning.
//
// Typing turns the change into one delete and one insert at the spot that
// changed. A remote change rewrites the value and moves the caret by the
// characters inserted or deleted before it, so typing isn't interrupted.
// Positions are UTF-16 units on both sides, as Yjs and the DOM count them.

const ORIGIN = Symbol("text field")

export function bindTextField(el, text) {
  const onInput = () => {
    const before = text.toString()
    const after = el.value
    if (before === after) return
    let start = 0
    while (start < before.length && start < after.length && before[start] === after[start]) start++
    let end = 0
    while (end < before.length - start && end < after.length - start &&
           before[before.length - 1 - end] === after[after.length - 1 - end]) end++
    text.doc.transact(() => {
      const removed = before.length - start - end
      if (removed > 0) text.delete(start, removed)
      const added = after.slice(start, after.length - end)
      if (added) text.insert(start, added)
    }, ORIGIN)
  }

  const onChange = (event, transaction) => {
    if (transaction.origin === ORIGIN) return
    const { selectionStart, selectionEnd, selectionDirection } = el
    el.value = text.toString()
    if (selectionStart === null) return
    el.setSelectionRange(moved(selectionStart, event.delta), moved(selectionEnd, event.delta), selectionDirection)
  }

  el.value = text.toString()
  el.addEventListener("input", onInput)
  text.observe(onChange)
  return () => {
    el.removeEventListener("input", onInput)
    text.unobserve(onChange)
  }
}

// Where a caret at `position` lands after `delta`: text inserted or deleted
// before it moves it, text after it doesn't.
export function moved(position, delta) {
  let index = 0
  let shift = 0
  for (const op of delta) {
    if (index >= position) break
    if (op.retain) index += op.retain
    else if (op.insert) shift += op.insert.length
    else if (op.delete) {
      shift -= Math.min(op.delete, position - index)
      index += op.delete
    }
  }
  return position + shift
}
