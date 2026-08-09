defmodule Twelvgaige.Sandbox.Backend.Mock do
  @moduledoc "In-memory sandbox backend for lifecycle contract tests."
  @behaviour Twelvgaige.Sandbox.Backend

  @impl true
  def probe(opts),
    do: {:ok, %{available: Keyword.get(opts, :available?, true), version: "mock-1"}}

  @impl true
  def prepare(spec, _opts) do
    manifest = Map.put(spec, :backend, :mock)
    {:ok, Map.put(manifest, :digest, digest(manifest))}
  end

  @impl true
  def create(manifest, _opts),
    do: {:ok, Twelvgaige.ID.new(:sandbox), %{status: :created, manifest: manifest}}

  @impl true
  def start(resource_id, _opts), do: {:ok, %{resource_id: resource_id, status: :running}}

  @impl true
  def inspect(resource_id, opts),
    do: {:ok, Keyword.get(opts, :observed, %{resource_id: resource_id, status: :running})}

  @impl true
  def stop(_resource_id, _opts), do: :ok

  @impl true
  def destroy(_resource_id, _opts), do: :ok

  @impl true
  def reconcile(durable, opts) do
    observed = Keyword.get(opts, :observed, durable)
    if observed == durable, do: {:ok, :resume, observed}, else: {:ok, :quarantine, observed}
  end

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
end
