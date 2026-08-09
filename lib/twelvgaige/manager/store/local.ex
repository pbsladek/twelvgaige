defmodule Twelvgaige.Manager.Store.Local do
  @moduledoc "Single-user durable manager store backed by an owner-only atomic state file."

  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    Twelvgaige.Manager.Store.Memory.start_link(Keyword.put(opts, :persistence_path, path))
  end
end
