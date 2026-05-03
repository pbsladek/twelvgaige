defmodule Twelvgaige.Store.SQLite.Schema.RoundEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "round_events" do
    field(:round_id, :string, primary_key: true)
    field(:seq, :integer, primary_key: true)
    field(:event, :binary)
  end
end
