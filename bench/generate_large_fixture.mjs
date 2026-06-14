// Generates a large ProseMirror Y.Doc update for the parallelism benchmark.
// Run: bun bench/generate_large_fixture.mjs > bench/large_update.bin
import * as Y from 'yjs'

const PARAGRAPHS = 2000
const WORDS = ['collaborative', 'editing', 'requires', 'conflict-free', 'replicated',
  'data', 'types', 'so', 'that', 'every', 'client', 'converges', 'without',
  'coordination', 'or', 'central', 'locking', 'across', 'the', 'network']

const doc = new Y.Doc()
const fragment = doc.getXmlFragment('prosemirror')

doc.transact(() => {
  const heading = new Y.XmlElement('heading')
  heading.setAttribute('level', '1')
  heading.insert(0, [new Y.XmlText('Benchmark Document')])
  fragment.insert(0, [heading])

  for (let i = 0; i < PARAGRAPHS; i++) {
    const p = new Y.XmlElement('paragraph')
    const t = new Y.XmlText()
    let text = `Paragraph ${i}: `
    for (let w = 0; w < 30; w++) text += WORDS[(i + w) % WORDS.length] + ' '
    t.insert(0, text)
    // sprinkle some formatting so extraction exercises mark handling
    t.format(11, 8, { bold: true })
    t.format(25, 6, { italic: true })
    p.insert(0, [t])
    fragment.insert(i + 1, [p])
  }
})

const update = Y.encodeStateAsUpdate(doc)
process.stdout.write(Buffer.from(update))
console.error(`paragraphs=${PARAGRAPHS} updateBytes=${update.length}`)
