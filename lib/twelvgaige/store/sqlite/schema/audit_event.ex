defmodule Twelvgaige.Store.SQLite.Schema.AuditEvent do
  @moduledoc false

  use Ecto.Schema

  schema "audit_events" do
    field(:round_id, :string)
    field(:event, :binary)
  end
end
