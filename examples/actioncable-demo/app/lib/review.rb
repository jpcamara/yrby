# frozen_string_literal: true

# What the agent has to say about a document: a short summary paragraph and a
# few suggestions. ReviewAgent writes it into the document as a heading, a
# paragraph, and a bulleted list.
Review = Data.define(:summary, :suggestions)
