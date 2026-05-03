defmodule Twelvgaige.Store.SQLite.Schema.Manifest do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "manifests" do
    field(:round_id, :string, primary_key: true)
    field(:manifest, :binary)
  end
end
