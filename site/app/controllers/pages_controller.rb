class PagesController < ApplicationController
  before_action :cache_page

  def index
  end

  def lexxy
  end

  private

  def cache_page
    expires_in Limits::DOCS_MAX_AGE.seconds,
               public: true,
               stale_while_revalidate: Limits::DOCS_STALE_WHILE_REVALIDATE.seconds
  end
end
