# yrby-forms

Collaborative form fields over [yrby](https://github.com/jpcamara/yrby). Two
custom elements, no framework:

- `<collaborative-form>` builds an Action Cable consumer, a `Y.Doc`, and
  [yrby-client](https://www.npmjs.com/package/yrby-client)'s
  `ActionCableProvider` from its attributes. One element per record; it
  carries the presence identity and reflects the connection status into its
  `status` attribute (`connecting` / `connected` / `synced` / `disconnected`).
- `<collaborative-field>` binds the one form control inside it to the form's
  shared document. `tier="lww"` binds the control's value to an entry in the
  shared `fields` map: each write replaces the value, last write wins per
  field. `tier="text"` binds a text control to a `fields/<name>` Y.Text:
  concurrent typing merges per character. While a remote peer focuses the
  same field, the wrapper shows their color as an outline and their name as
  a chip.

The elements are rendered by the companion Rails gem's form helpers
(`form.collaborative_fields` / `form.collaborative_field`); see
[README-forms.md](https://github.com/jpcamara/yrby/blob/main/README-forms.md)
for the whole system, the document layout, and the authorization posture.

## Install

```sh
npm install yrby-forms yjs y-protocols
```

Import it once from your entry point; importing registers the elements:

```js
import "yrby-forms"
```

The consumer comes from `@rails/actioncable`'s `createConsumer()`, which
reads the standard `action-cable-url` meta tag. For another transport
(AnyCable), supply the consumer at boot:

```js
import { createConsumer } from "@anycable/web"
import { setConsumer } from "yrby-forms"

setConsumer(() => createConsumer())
```

A consumer assigned directly on a `<collaborative-form>` element (the
`consumer` property, before insertion) still wins.

## Element attributes

```html
<collaborative-form channel-name="FormFieldsChannel"
                    channel-params='{"sgid":"…","field":"fields"}'
                    doc-id="ticket-1-fields" name="Ada" color="#22d3ee">
  <collaborative-field name="status" tier="lww">
    <select name="ticket[status]">…</select>
  </collaborative-field>
  <collaborative-field name="description" tier="text">
    <textarea name="ticket[description]"></textarea>
  </collaborative-field>
</collaborative-form>
```

`channel-name` names the server channel, `channel-params` is the JSON
subscription params (the signed record token the channel authorizes, plus
the field-set name), `doc-id` is the client-side document id, and `name` /
`color` are the presence identity — the same wiring yrby-rails'
`collaborative_document_tag` emits for every collaborative element. Names
are cosmetic; access is enforced server-side by the signed token and the
channel's `authorized?`.

## Styling

The presence affordances ship as one injected `<style id="yrby-forms-styles">`
tag. Override its selectors, or pre-insert your own element with that id to
suppress the injection.

## License

MIT
