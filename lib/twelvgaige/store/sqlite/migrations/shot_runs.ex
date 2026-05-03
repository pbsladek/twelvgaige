defmodule Twelvgaige.Store.SQLite.Migrations.ShotRuns do
  @moduledoc false

  use Ecto.Migration

  @version 20_260_501_000_200

  @spec version() :: pos_integer()
  def version, do: @version

  def change do
    create_if_not_exists table(:shot_runs, primary_key: false) do
      add(:round_id, references(:rounds, type: :text, column: :id, on_delete: :delete_all),
        primary_key: true
      )

      add(:shot_id, :text, primary_key: true)
      add(:kind, :text, null: false)
      add(:status, :text, null: false)
      add(:attempt, :integer, null: false)
      add(:started_at, :text)
      add(:completed_at, :text)
      add(:next_retry_at, :text)
      add(:output, :binary)
      add(:error, :binary)
    end

    create_if_not_exists(index(:shot_runs, [:round_id, :status]))
    create_if_not_exists(index(:shot_runs, [:status]))
  end
end
