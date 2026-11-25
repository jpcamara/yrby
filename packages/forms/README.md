# yrby-forms

Collaborative form fields over [yrby](https://github.com/jpcamara/yrby). The
package adds one custom element, `<collaborative-field>`, and uses
[yrby-client](https://www.npmjs.com/package/yrby-client)'s `<yrby-document>`
for the connection.

`<collaborative-field>` binds the form control inside it to the document of
the `<yrby-document>` around it. It binds when the document syncs and unbinds
when the document's lease ends.

- `tier="lww"` binds the control's value to an entry in the shared `fields`
  map. Each write replaces the value, and the last write wins.
- `tier="text"` binds a text control to a `fields/<name>` Y.Text, so
  concurrent typing merges per character.

While another person has the same field focused, the field shows their color
as an outline and their name as a chip.

The companion Rails gem's form helpers (`form.collaborative_fields` and
`form.collaborative_field`) render both elements. See
[README-forms.md](https://github.com/jpcamara/yrby/blob/main/README-forms.md)
for the Rails side and the document layout.

## Install

```sh
npm install yrby-forms yjs y-protocols @rails/actioncable
```

Import it once from your entry point. Importing registers both elements:

```js
import "yrby-forms"
```

The connection is yrby-client's. To use another consumer, such as AnyCable's,
assign it before the elements are added:

```js
import { createConsumer } from "@anycable/web"
import { YrbyDocumentElement } from "yrby-client/element"

YrbyDocumentElement.consumer = () => createConsumer()
```

## Markup

```html
<yrby-document channel="Y::Forms::FieldsChannel" grant="…" name="fields"
               data-user-name="Ada" data-user-color="#22d3ee">
  <collaborative-field name="status" tier="lww">
    <select name="ticket[status]">…</select>
  </collaborative-field>
  <collaborative-field name="description" tier="text">
    <textarea name="ticket[description]"></textarea>
  </collaborative-field>
</yrby-document>
```

`channel`, `grant`, and `name` are `<yrby-document>`'s own attributes.
`data-user-name` and `data-user-color` are what other people see on a field
you have focused. The browser sets them, so treat them as labels. The signed
grant is what gives access.

A field sets its presence to `{ user: { name, color }, field }`. `field` is
the focused field's name, or `null`.

## Styling

The outline and chip styles ship as one injected
`<style id="yrby-forms-styles">` tag. Override its selectors, or add your own
element with that id first and the package injects nothing.

## License

MIT
