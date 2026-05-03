defmodule Twelvgaige.Store.SQLite.Schema.ShotRun do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "shot_runs" do
    field(:round_id, :string, primary_key: true)
    field(:shot_id, :string, primary_key: true)
    field(:kind, :string)
    field(:status, :string)
    field(:attempt, :integer)
    field(:started_at, :string)
    field(:completed_at, :string)
    field(:next_retry_at, :string)
    field(:output, :binary)
    field(:error, :binary)
  end
end
