defmodule Twelvgaige.ID.Random do
  @moduledoc """
  Cryptographically strong random ID generator.
  """

  @behaviour Twelvgaige.ID

  @impl true
  def new(prefix) do
    suffix =
      12
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    Twelvgaige.ID.prefix_slug(prefix) <> "_" <> suffix
  end
end
