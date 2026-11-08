# frozen_string_literal: true

Rage.routes.draw do
  get "docs/:id", to: "documents#show"
  post "docs/:id/append", to: "documents#append"
  get "token", to: "documents#token"
  mount AnyCable::HTTRPC::Server.new, at: "/_anycable"
end
