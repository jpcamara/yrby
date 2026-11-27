class CreateExampleDocuments < ActiveRecord::Migration[8.1]
  def up
    create_table :example_documents, &:timestamps
    # Create the one public example here, so anonymous page views never create
    # records.
    execute <<~SQL
      INSERT INTO example_documents (id, created_at, updated_at) VALUES (1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def down
    drop_table :example_documents
  end
end
