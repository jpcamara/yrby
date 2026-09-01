# frozen_string_literal: true

require "rails/generators"
require "generators/yrby/tables/tables_generator"

module YrbyForms
  module Generators
    # `bin/rails generate yrby_forms:install` — a FormFieldsChannel syncing
    # each record's field-set document, plus the storage migration (via
    # yrby:tables). The models and helpers ship in the gems; only the channel
    # and the migration land in the app.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def create_channel
        template "form_fields_channel.rb", "app/channels/form_fields_channel.rb"
      end

      # yrby owns the models and their migration.
      def create_tables
        invoke "yrby:tables"
      end

      def show_next_steps
        say <<~NEXT

          yrby-forms is installed. Next steps:

            1. Authorize access: implement `authorized?` in
               app/channels/form_fields_channel.rb (it denies everyone until you do).
            2. bin/rails db:migrate
            3. Declare fields on a model and render them:

                 has_collaborative_fields :status, :summary, :description

                 <%= form.collaborative_fields do %>
                   <%= form.collaborative_field :status %>
                 <% end %>

            4. Install the yrby-forms npm package and import it from your
               JavaScript entry point (it registers the elements).

          Optional: set presence names with `Y::Collaborative.identity`.
        NEXT
      end
    end
  end
end
