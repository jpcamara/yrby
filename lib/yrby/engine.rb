# frozen_string_literal: true

require "rails/engine"
require "action_dispatch" # Engine::Configuration references it at subclass definition

module Yrby
  # The Rails engine. Autoloads the gem's models (Y::Document,
  # Y::DocumentUpdate) from app/models, puts the collaborative-document
  # macros on every model, and adds collaborative_document_tag to form
  # builders.
  class Engine < ::Rails::Engine
    initializer "yrby.collaborative" do
      ActiveSupport.on_load(:active_record) { include Y::Collaborative }
    end

    initializer "yrby.collaborative.form_builder" do |app|
      app.config.to_prepare { ActionView::Helpers::FormBuilder.prepend(Y::Collaborative::FormBuilder) }
    end
  end
end
