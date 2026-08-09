defmodule Twelvgaige.Sandbox.BackendSelector do
  @moduledoc "Explicit sandbox backend selection and operator diagnostics."

  alias Twelvgaige.Sandbox.Backend.{AppleContainer, Podman}

  @backends %{podman: Podman, apple_container: AppleContainer}

  @doc "Resolves and probes a backend. `:auto` deliberately means Podman; it never weakens isolation by fallback."
  def resolve(selection, opts \\ []) when selection in [:auto, :podman, :apple_container] do
    selection = if selection == :auto, do: :podman, else: selection
    backend = Map.fetch!(@backends, selection)

    case backend.probe(Keyword.get(opts, selection, opts)) do
      {:ok, probe} -> {:ok, backend, probe}
      {:error, reason} -> {:error, {:sandbox_backend_unavailable, selection, reason}}
    end
  end

  @doc "Reports both installed backends without allowing one backend to mask failure in the other."
  def diagnostics(opts \\ []) do
    Map.new(@backends, fn {name, backend} ->
      result =
        case backend.probe(Keyword.get(opts, name, opts)) do
          {:ok, probe} -> %{status: :ready, probe: probe}
          {:error, reason} -> %{status: :unavailable, reason: reason}
        end

      {name, result}
    end)
  end
end
