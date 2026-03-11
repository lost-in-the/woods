class CreateWoodsTables < ActiveRecord::Migration[7.0]
  def change
    create_table :woods_units do |t|
      t.string :unit_type, null: false
      t.string :identifier, null: false
      t.string :namespace
      t.string :file_path, null: false
      t.text :source_code
      t.string :source_hash
      t.json :metadata

      t.timestamps
    end

    add_index :woods_units, :unit_type
    add_index :woods_units, :identifier, unique: true
    add_index :woods_units, :file_path

    create_table :woods_edges do |t|
      t.references :source, null: false, foreign_key: { to_table: :woods_units }
      t.references :target, null: false, foreign_key: { to_table: :woods_units }
      t.string :relationship, null: false
      t.string :via

      t.datetime :created_at, null: false
    end

    add_index :woods_edges, [:source_id, :target_id, :relationship], unique: true,
              name: 'idx_woods_edges_unique'

    create_table :woods_embeddings do |t|
      t.references :unit, null: false, foreign_key: { to_table: :woods_units }
      t.string :chunk_type
      t.text :embedding, null: false
      t.string :content_hash, null: false
      t.integer :dimensions, null: false

      t.datetime :created_at, null: false
    end

    add_index :woods_embeddings, :content_hash
  end
end
