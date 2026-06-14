// Generates the ProseMirrorDoc fixture in yjs_fixtures.rb
// Regenerate with: bun test/fixtures/generate_prosemirror_fixture.mjs
import * as Y from 'yjs'

const doc = new Y.Doc()
const frag = doc.getXmlFragment('prosemirror')

// heading level 1: "Title"
const h = new Y.XmlElement('heading')
h.setAttribute('level', '1')
const ht = new Y.XmlText()
ht.insert(0, 'Title')
h.insert(0, [ht])

// paragraph: "Hello " + bold "bold" + " and a " + link "link"
const p = new Y.XmlElement('paragraph')
const t = new Y.XmlText()
t.insert(0, 'Hello ')
t.insert(6, 'bold', { bold: true })
t.insert(10, ' and a ', { bold: null })
t.insert(17, 'link', { link: 'https://example.com' })
p.insert(0, [t])

frag.insert(0, [h, p])

const update = Y.encodeStateAsUpdate(doc)
console.log(Buffer.from(update).toString('base64'))
