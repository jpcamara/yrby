class PagesController < ApplicationController
  def index
    expires_in Limits::DOCS_MAX_AGE.seconds,
               public: true,
               stale_while_revalidate: Limits::DOCS_STALE_WHILE_REVALIDATE.seconds
  end
end
