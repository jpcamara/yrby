class CreateExampleDocuments < ActiveRecord::Migration[8.1]
  def up
    create_table :example_documents, &:timestamps
    # One public example, provisioned by deployment rather than anonymous GETs.
    execute <<~SQL
      INSERT INTO example_documents (id, created_at, updated_at) VALUES (1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def down
    drop_table :example_documents
  end
end
