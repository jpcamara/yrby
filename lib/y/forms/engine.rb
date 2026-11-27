# frozen_string_literal: true

require "rails/engine"
require "action_dispatch" # Engine::Configuration references it at subclass definition

# Require the engine dependencies explicitly so their initializers run
# during boot.
require "y"
require "yrby-rails" # the sync concern, Y::Document storage, and yrby's engine
# The channels are eager loaded with the app. An app whose fields all live in
# a column may not load Action Cable, and the channels still need its classes.
require "action_cable"

module Y
  module Forms
    class Engine < ::Rails::Engine
      initializer "y_forms.active_record" do
        ActiveSupport.on_load(:active_record) { include Y::Forms::CollaborativeFields }
      end

      initializer "y_forms.form_builder" do |app|
        app.config.to_prepare { ActionView::Helpers::FormBuilder.prepend(Y::Forms::FormBuilder) }
      end
    end
  end
end
