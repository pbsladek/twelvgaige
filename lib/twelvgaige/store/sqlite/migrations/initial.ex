defmodule Twelvgaige.Store.SQLite.Migrations.Initial do
  @moduledoc false

  use Ecto.Migration

  @version 20_260_501_000_100

  @spec version() :: pos_integer()
  def version, do: @version

  def change do
    create_if_not_exists table(:rounds, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:status, :text, null: false)
      add(:version, :integer, null: false)
      add(:snapshot, :binary, null: false)
      add(:inserted_at, :text, null: false)
      add(:updated_at, :text, null: false)
    end

    create_if_not_exists(index(:rounds, [:status]))

    create_if_not_exists table(:manifests, primary_key: false) do
      add(:round_id, references(:rounds, type: :text, column: :id, on_delete: :delete_all),
        primary_key: true
      )

      add(:manifest, :binary, null: false)
    end

    create_if_not_exists table(:round_events, primary_key: false) do
      add(:round_id, references(:rounds, type: :text, column: :id, on_delete: :delete_all),
        primary_key: true
      )

      add(:seq, :integer, primary_key: true)
      add(:event, :binary, null: false)
    end

    create_if_not_exists(index(:round_events, [:round_id, :seq]))

    create_if_not_exists table(:audit_events) do
      add(:round_id, :text, null: false)
      add(:event, :binary, null: false)
    end

    create_if_not_exists(index(:audit_events, [:round_id]))

    create_if_not_exists table(:committed_transitions, primary_key: false) do
      add(:round_id, references(:rounds, type: :text, column: :id, on_delete: :delete_all),
        primary_key: true
      )

      add(:transition_id, :text, primary_key: true)
    end

    create_if_not_exists table(:attempt_journals, primary_key: false) do
      add(:round_id, :text, primary_key: true)
      add(:shot_id, :text, primary_key: true)
      add(:attempt, :integer, primary_key: true)
      add(:status, :text, null: false)
      add(:journal, :binary, null: false)
    end

    create_if_not_exists(index(:attempt_journals, [:round_id, :shot_id, :attempt]))

    create_if_not_exists table(:tool_journals, primary_key: false) do
      add(:round_id, :text, primary_key: true)
      add(:shot_id, :text, primary_key: true)
      add(:attempt, :integer, primary_key: true)
      add(:tool_key, :text, primary_key: true)
      add(:status, :text, null: false)
      add(:journal, :binary, null: false)
    end

    create_if_not_exists(index(:tool_journals, [:round_id, :shot_id, :attempt, :tool_key]))
  end
end
