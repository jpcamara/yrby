/** The map share holding the LWW entries; text shares live at `fields/<name>`. */
export const FIELDS_MAP = "fields";
/**
 * The one changed region between two strings, as a splice: common prefix and
 * suffix stay, the middle becomes one delete + one insert. Null when equal.
 */
export function diffSplice(oldValue, newValue) {
    if (oldValue === newValue)
        return null;
    let start = 0;
    while (start < oldValue.length && start < newValue.length && oldValue[start] === newValue[start])
        start++;
    let oldEnd = oldValue.length;
    let newEnd = newValue.length;
    while (oldEnd > start && newEnd > start && oldValue[oldEnd - 1] === newValue[newEnd - 1]) {
        oldEnd--;
        newEnd--;
    }
    return { index: start, deleteCount: oldEnd - start, insert: newValue.slice(start, newEnd) };
}
const isCheckbox = (control) => control instanceof HTMLInputElement && control.type === "checkbox";
/** Bind a control to the shared map entry under `name`. Returns the unbind. */
export function bindLww(doc, name, control) {
    const map = doc.getMap(FIELDS_MAP);
    const origin = {};
    const read = () => (isCheckbox(control) ? control.checked : control.value);
    const write = (value) => {
        if (isCheckbox(control))
            control.checked = value === true;
        else {
            const text = value == null ? "" : String(value);
            if (control.value !== text)
                control.value = text;
        }
    };
    const onInput = () => {
        if (map.get(name) === read())
            return;
        doc.transact(() => map.set(name, read()), origin);
    };
    control.addEventListener("input", onInput);
    control.addEventListener("change", onInput);
    const observer = (event, transaction) => {
        if (transaction.origin === origin || !event.keysChanged.has(name))
            return;
        write(map.get(name));
    };
    map.observe(observer);
    if (map.has(name))
        write(map.get(name)); // rebinding into an already-loaded doc
    return () => {
        control.removeEventListener("input", onInput);
        control.removeEventListener("change", onInput);
        map.unobserve(observer);
    };
}
/** Bind a text control to the `fields/<name>` Y.Text. Returns the unbind. */
export function bindText(doc, name, control) {
    const text = doc.getText(`${FIELDS_MAP}/${name}`);
    const origin = {};
    // The last value control and share agreed on; each input event splices the
    // difference from it into the share.
    let shadow = control.value;
    if (text.length > 0)
        shadow = control.value = text.toString(); // rebinding into an already-loaded doc
    const onInput = () => {
        const change = diffSplice(shadow, control.value);
        shadow = control.value;
        if (!change)
            return;
        doc.transact(() => {
            if (change.deleteCount > 0)
                text.delete(change.index, change.deleteCount);
            if (change.insert)
                text.insert(change.index, change.insert);
        }, origin);
    };
    control.addEventListener("input", onInput);
    const observer = (_event, transaction) => {
        if (transaction.origin === origin)
            return;
        const value = text.toString();
        if (control.value === value) {
            shadow = value;
            return;
        }
        // Rewrite the control, keeping the local caret in place: a remote change
        // landing before it shifts it by the length delta.
        const change = diffSplice(control.value, value);
        const caret = control.selectionStart;
        const focused = control.ownerDocument.activeElement === control;
        control.value = value;
        shadow = value;
        if (focused && change && caret != null) {
            const position = change.index <= caret ? Math.max(change.index, caret + change.insert.length - change.deleteCount) : caret;
            control.setSelectionRange(position, position);
        }
    };
    text.observe(observer);
    return () => {
        control.removeEventListener("input", onInput);
        text.unobserve(observer);
    };
}
//# sourceMappingURL=bindings.js.map