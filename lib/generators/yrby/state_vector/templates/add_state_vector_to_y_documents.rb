# frozen_string_literal: true

class AddStateVectorToYDocuments < ActiveRecord::Migration<%= migration_version %>
  def change
    add_column :y_documents, :state_vector, :binary
  end
end
