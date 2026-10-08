# The docs pages can respond with markdown, because coding agents parse it more
# easily than HTML. `Accept: text/markdown` and the `.md` routes return it.
# Rails doesn't register text/markdown by default.
Mime::Type.register "text/markdown", :md
