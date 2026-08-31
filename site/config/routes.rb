Rails.application.routes.draw do
  root "pages#index"

  get "up" => "rails/health#show", as: :rails_health_check

  get "docs", to: redirect("/docs/getting-started")
  get "docs/:page", to: "docs#show", as: :doc, constraints: { page: /[a-z0-9-]+/ }

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
