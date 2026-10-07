# Documentation pages. They're markdown rendered on the server with nothing
# specific to a visitor, so a CDN can serve almost all of this traffic.
class DocsController < ApplicationController
  def show
    @page = DocPage.find(params[:page])
    return head :not_found if @page.nil?

    cache_publicly
    respond_to do |format|
      format.html { render :show }
      # The raw markdown, for `Accept: text/markdown` and `/docs/:page.md`.
      # Coding agents read markdown best. DocPage already holds the source, so
      # this costs almost nothing.
      format.md do
        render plain: @page.markdown_with_frontmatter(canonical_url("/docs/#{@page.slug}")),
               content_type: "text/markdown"
      end
    end
  end

  private

  # public, max-age=1h, stale-while-revalidate=24h. The CDN serves from cache
  # for an hour. After that it serves the stale copy while it refreshes in the
  # background. A deploy doesn't send a burst of cache misses to the single
  # process, and readers don't notice a restart.
  def cache_publicly
    expires_in Limits::DOCS_MAX_AGE.seconds,
               public: true,
               stale_while_revalidate: Limits::DOCS_STALE_WHILE_REVALIDATE.seconds
  end
end
