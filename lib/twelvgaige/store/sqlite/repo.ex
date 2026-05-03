defmodule Twelvgaige.Store.SQLite.Repo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :twelvgaige,
    adapter: Ecto.Adapters.SQLite3
end
