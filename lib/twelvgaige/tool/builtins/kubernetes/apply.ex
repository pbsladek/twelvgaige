defmodule Twelvgaige.Tool.Builtins.Kubernetes.Apply do
  @moduledoc """
  Apply a manifest file through structured `kubectl apply` argv.

  The manifest must be an explicit regular file below a trusted root. Inline
  manifests and arbitrary kubectl flags are intentionally unsupported.
  """

  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Tool.Builtins.Kubernetes.Common
  alias Twelvgaige.Tool.Idempotency

  @allowed_extensions ~w(.yaml .yml .json)

  @impl true
  def name, do: "kubectl_apply"

  @impl true
  def description, do: "Apply a trusted Kubernetes manifest file through structured kubectl argv."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "required" => ["namespace", "path", "confirm"],
      "properties" => %{
        "context" => %{"type" => "string"},
        "namespace" => %{"type" => "string"},
        "path" => %{"type" => "string"},
        "confirm" => %{"type" => "boolean"},
        "max_bytes" => %{"type" => "integer"}
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def safety_level, do: :idempotent_write

  @impl true
  def idempotency do
    Idempotency.idempotent(
      reconciliation_strategy: :read_after_write,
      side_effect_phase: :unknown
    )
  end

  @impl true
  def execute(input, opts) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

    with :ok <- Common.require_confirm(input, name()),
         {:ok, context} <- Common.context(input, opts),
         {:ok, namespace} <- Common.required_string(input, "namespace"),
         {:ok, manifest_path, relative_path} <- manifest_path(input, root),
         {:ok, max_bytes} <- Common.max_bytes(input, opts),
         target <- target(context, namespace, relative_path),
         {:ok, result} <- Common.run_kubectl(args(target, manifest_path), target, opts),
         {excerpt, truncated} <- Common.bounded_excerpt(result.stdout, max_bytes) do
      {:ok,
       Common.output_base(target, "apply", result.duration_ms)
       |> Map.merge(%{
         manifest_path: relative_path,
         text_excerpt: excerpt,
         truncated: truncated,
         output_bytes: byte_size(excerpt),
         exit_status: result.status
       })
       |> stringify_keys()}
    end
  end

  defp manifest_path(input, root) do
    with {:ok, path} <- Common.required_string(input, "path"),
         expanded_root <- Path.expand(root),
         expanded_path <- Path.expand(path, expanded_root),
         :ok <- ensure_within_root(expanded_path, expanded_root),
         :ok <- ensure_manifest_extension(expanded_path),
         :ok <- ensure_no_symlink_components(expanded_path, expanded_root),
         :ok <- ensure_regular_file(expanded_path) do
      relative_path =
        expanded_path
        |> Path.relative_to(expanded_root)
        |> Path.split()
        |> Path.join()

      {:ok, expanded_path, relative_path}
    end
  end

  defp ensure_within_root(expanded_path, expanded_root) do
    relative = Path.relative_to(expanded_path, expanded_root)

    if expanded_path != expanded_root and within_relative_path?(relative) do
      :ok
    else
      Common.tool_error(:tool_denied, "manifest path is outside the allowed root", %{
        path: expanded_path,
        root: expanded_root
      })
    end
  end

  defp within_relative_path?(relative) do
    relative != ".." and
      not String.starts_with?(relative, "../") and
      Path.type(relative) == :relative
  end

  defp ensure_manifest_extension(expanded_path) do
    extension = expanded_path |> Path.extname() |> String.downcase()

    if extension in @allowed_extensions do
      :ok
    else
      Common.tool_error(:tool_input_invalid, "manifest path must be YAML or JSON", %{
        path: expanded_path,
        allowed_extensions: @allowed_extensions
      })
    end
  end

  defp ensure_no_symlink_components(expanded_path, expanded_root) do
    relative = Path.relative_to(expanded_path, expanded_root)

    relative
    |> Path.split()
    |> Enum.reduce_while({:ok, expanded_root}, fn segment, {:ok, acc} ->
      current = Path.join(acc, segment)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} ->
          {:halt,
           Common.tool_error(:tool_denied, "symlink manifest paths are denied", %{
             path: current,
             root: expanded_root
           })}

        {:ok, _stat} ->
          {:cont, {:ok, current}}

        {:error, reason} ->
          {:halt,
           Common.tool_error(:tool_non_retryable, "could not inspect manifest path", %{
             path: current,
             reason: reason
           })}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp ensure_regular_file(expanded_path) do
    if File.regular?(expanded_path) do
      :ok
    else
      Common.tool_error(:tool_non_retryable, "manifest path is not a regular file", %{
        path: expanded_path
      })
    end
  end

  defp target(context, namespace, relative_path) do
    %{
      context: context,
      namespace: namespace,
      resource: "manifest",
      cluster_scope?: false,
      name: relative_path,
      selector: nil,
      field_selector: nil
    }
  end

  defp args(target, manifest_path) do
    Common.base_args(target) ++ ["apply", "-f", manifest_path]
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
