Rails.application.routes.draw do
  root "pages#index"
  get "lexxy", to: "pages#lexxy"

  get "up" => "rails/health#show", as: :rails_health_check

  get "docs", to: redirect("/docs/getting-started")
  # `(.:format)` adds the `.md` variant (DocsController serves raw markdown for
  # it); the page constraint excludes dots, so `storage.md` parses as
  # page="storage", format=md.
  get "docs/:page(.:format)", to: "docs#show", as: :doc, constraints: { page: /[a-z0-9-]+/ }

  # Files for crawlers and LLMs, rendered from the doc and demo lists so they
  # stay in sync. They all use the one canonical host from ENV.
  get "robots.txt", to: "meta#robots"
  get "sitemap.xml", to: "meta#sitemap"
  get "llms.txt", to: "meta#llms"
  get "llms-full.txt", to: "meta#llms_full"

  get "examples/document", to: "examples#document"
  get "examples/document/stored", to: "examples#stored"

  get "demos", to: "demos#index"
  # A bare demo URL picks a room id and redirects to it, so every visitor gets
  # a separate room.
  get "demos/:demo", to: "demos#new_room", as: :demo
  # Starting a room creates its row (see DemosController#start). Without a
  # room it starts a new one, which is where the demo links go.
  post "demos/:demo/start", to: "demos#start", as: :demo_open
  post "demos/:demo/:room/start", to: "demos#start", as: :demo_start
  # The Lexxy demo's stored Action Text body (see DemosController#body).
  get "demos/lexxy/:room/body", to: "demos#body", as: :demo_room_body
  # The server-side read for the other demos: Ruby rebuilds the document from
  # stored state (see DemosController#stored).
  get "demos/:demo/:room/stored", to: "demos#stored", as: :demo_stored

  # The controller checks the room segment against Demos::ROOM_FORMAT, so a
  # malformed link gets a 404 from the controller. A route constraint would
  # turn it into a routing error.
  get "demos/:demo/:room", to: "demos#show", as: :demo_room

  # `form_with model: @room` on the Lexxy page needs a URL for a room. The
  # form never submits (there's no submit button, and no route takes a write),
  # so this only gives it the room's own Lexxy page.
  resolve("Room") { |room| route_for(:demo_room, "lexxy", room) }
end
