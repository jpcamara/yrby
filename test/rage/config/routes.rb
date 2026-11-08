# frozen_string_literal: true

Rage.routes.draw do
  get "docs/:id", to: "documents#show"
  post "docs/:id/append", to: "documents#append"
  mount Rage.cable.application, at: "/cable"
end
