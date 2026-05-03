defmodule Twelvgaige.Store.SQLite.Schema.Round do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "rounds" do
    field(:status, :string)
    field(:version, :integer)
    field(:shell_id, :string)
    field(:shell_version, :string)
    field(:started_at, :string)
    field(:completed_at, :string)
    field(:error_class, :string)
    field(:error_reason, :string)
    field(:snapshot, :binary)
    field(:inserted_at, :string)
    field(:updated_at, :string)
  end
end
