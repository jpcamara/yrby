# Documentation pages. Server-rendered markdown, no per-visitor content, so a
# CDN can serve nearly all of this traffic without the app seeing it.
class DocsController < ApplicationController
  def show
    @page = DocPage.find(params[:page])
    return head :not_found if @page.nil?

    cache_publicly
    render :show
  end

  private

  # public, max-age=1h, stale-while-revalidate=24h. The CDN answers from cache
  # for an hour, then keeps answering from the stale copy while it refreshes in
  # the background — so a deploy never sends a wave of misses at a single
  # process, and a restart is invisible to readers.
  def cache_publicly
    expires_in Limits::DOCS_MAX_AGE.seconds,
               public: true,
               stale_while_revalidate: Limits::DOCS_STALE_WHILE_REVALIDATE.seconds
  end
end
