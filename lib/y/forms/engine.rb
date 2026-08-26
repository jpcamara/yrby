# frozen_string_literal: true

require "rails/engine"
require "action_dispatch" # Engine::Configuration references it at subclass definition

# Require the engine dependencies explicitly so their initializers run
# during boot.
require "y"
require "yrby-rails" # the sync concern, Y::Document storage, and yrby's engine

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
