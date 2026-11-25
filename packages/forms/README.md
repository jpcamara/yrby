# yrby-forms

Collaborative form fields over [yrby](https://github.com/jpcamara/yrby). The
package adds `<collaborative-field>` and uses
[yrby-client](https://www.npmjs.com/package/yrby-client)'s `<yrby-document>`
for the connection. A second element, `<collaborative-fields>`, holds the
document for a form [without a connection](#without-a-connection).

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

Import it once from your entry point. Importing registers the elements:

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

## Without a connection

`<collaborative-fields>` holds the document for a form that opens no
connection. The server renders the document's state, as Base64, in the
element's `value` attribute:

```html
<form action="/drafts/1" method="post">
  <input type="hidden" name="_method" value="patch">
  <collaborative-fields name="draft[fields_ydoc]" value="AQH…" autosave>
    <collaborative-field name="title" tier="text">
      <input type="text" name="draft[title]">
    </collaborative-field>
    <collaborative-field name="body" tier="text">
      <textarea name="draft[body]"></textarea>
    </collaborative-field>
  </collaborative-fields>
</form>
```

- The element adds the current state to the form's data under its `name`, so
  a submit carries every edit. The server merges it into the state it holds.
- When the `value` attribute changes, the new state is merged into the open
  form. A Turbo morph of the page does this.
- With `autosave`, each edit posts the form after 300 ms. The response is the
  page the server renders next, and the element merges the state it finds in
  that page's `<collaborative-fields>` of the same `name`.
- A bound control cancels its own `turbo:before-morph-element`, so a morph
  does not replace what the person is typing.

There is no presence in this mode. A page that uses only this mode can skip
yrby-client:

```js
import "yrby-forms/column"
```

## Styling

The outline and chip styles ship as one injected
`<style id="yrby-forms-styles">` tag. Override its selectors, or add your own
element with that id first and the package injects nothing.

## License

MIT
