Rails.application.routes.draw do
  root "pages#index"

  get "up" => "rails/health#show", as: :rails_health_check

  get "docs", to: redirect("/docs/getting-started")
  # `(.:format)` adds the `.md` variant (DocsController serves raw markdown for
  # it); the page constraint excludes dots, so `storage.md` parses as
  # page="storage", format=md.
  get "docs/:page(.:format)", to: "docs#show", as: :doc, constraints: { page: /[a-z0-9-]+/ }

  # Discoverability endpoints, rendered from the doc/demo lists so they can't
  # drift (and so the canonical host is one ENV-driven value everywhere).
  get "robots.txt", to: "meta#robots"
  get "sitemap.xml", to: "meta#sitemap"
  get "llms.txt", to: "meta#llms"
  get "llms-full.txt", to: "meta#llms_full"

  get "demos", to: "demos#index"
  # A bare demo URL mints a room and redirects, so every visitor lands
  # somewhere private without having to think about it.
  get "demos/:demo", to: "demos#new_room", as: :demo
  # The Rich text demo's materialized column (see DemosController#body).
  get "demos/lexxy/:room/body", to: "demos#body", as: :demo_note_body

  # The room segment's shape is checked in the controller against
  # Demos::ROOM_FORMAT rather than here, so an odd link 404s instead of falling
  # through to a routing error.
  get "demos/:demo/:room", to: "demos#show", as: :demo_room
end
