defmodule Twelvgaige.Store.SQLite.Migrations.RoundQueryColumns do
  @moduledoc false

  use Ecto.Migration

  @version 20_260_501_000_300

  @spec version() :: pos_integer()
  def version, do: @version

  def change do
    alter table(:rounds) do
      add(:shell_id, :text)
      add(:shell_version, :text)
      add(:started_at, :text)
      add(:completed_at, :text)
      add(:error_class, :text)
      add(:error_reason, :text)
    end

    create_if_not_exists(index(:rounds, [:shell_id]))
    create_if_not_exists(index(:rounds, [:status, :shell_id]))
    create_if_not_exists(index(:rounds, [:started_at]))
    create_if_not_exists(index(:rounds, [:completed_at]))
    create_if_not_exists(index(:rounds, [:error_reason]))
  end
end
