# Markdown is a first-class response format for the docs: coding agents parse it
# better than HTML, and it is what `Accept: text/markdown` and the `.md` routes
# serve. Rails knows text/html and application/json out of the box but not this.
Mime::Type.register "text/markdown", :md
