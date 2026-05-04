defmodule Twelvgaige.Shell.Metadata do
  @moduledoc """
  Authoring metadata carried by workflow and shot shells.

  Metadata is intentionally not part of runtime orchestration semantics. It is
  preserved for review, inventory, provenance, and CI admission checks.
  """

  alias Twelvgaige.Shell.Validation, as: V

  @workflow_keys ~w(owner tags lifecycle lifecycle_reason generated_by maintainers review approval source)
  @shot_keys ~w(owner tags lifecycle generated_by maintainers review approval purpose last_reviewed)
  @generated_by_keys ~w(tool command version source)
  @source_keys ~w(kind id version hash digest path namespace repository)
  @review_keys ~w(workflow_digest agent_digests loadout_digest reviewer reviewed_at scope evidence_hash)
  @approval_keys ~w(workflow_digest agent_digests loadout_digest approver approved_at scope expires_at evidence_hash)
  @lifecycles [:draft, :reviewed, :approved, :scheduled, :deprecated, :retired]
  @max_encoded_bytes 8_192
  @digest_regex ~r/^sha256:[0-9a-f]{64}$/

  @type scope :: :workflow | :shot
  @type t :: %__MODULE__{
          owner: String.t() | nil,
          tags: [String.t()],
          lifecycle: atom() | nil,
          lifecycle_reason: String.t() | nil,
          generated_by: map() | nil,
          maintainers: [String.t()],
          review: map() | nil,
          approval: map() | nil,
          source: map() | nil,
          purpose: String.t() | nil,
          last_reviewed: String.t() | nil
        }

  defstruct owner: nil,
            tags: [],
            lifecycle: nil,
            lifecycle_reason: nil,
            generated_by: nil,
            maintainers: [],
            review: nil,
            approval: nil,
            source: nil,
            purpose: nil,
            last_reviewed: nil

  @spec from_map(term(), [term()], scope()) :: {:ok, t()} | {:error, Twelvgaige.Error.t()}
  def from_map(nil, _path, _scope), do: {:ok, %__MODULE__{}}

  def from_map(map, path, scope) when scope in [:workflow, :shot] do
    with {:ok, map} <- V.map(map, path),
         :ok <- V.known_keys(map, keys(scope), path),
         :ok <- enforce_size(map, path),
         {:ok, owner} <- V.optional_non_empty_string(map, :owner, path),
         {:ok, tags} <- V.optional_slug_list(map, :tags, [], path),
         {:ok, lifecycle} <- optional_lifecycle(map, path),
         {:ok, lifecycle_reason} <- scoped_string(scope, map, :lifecycle_reason, path),
         {:ok, generated_by} <- generated_by(V.optional(map, :generated_by, nil), path),
         {:ok, maintainers} <- maintainers(map, path),
         {:ok, review} <- binding(:review, V.optional(map, :review, nil), path),
         {:ok, approval} <- binding(:approval, V.optional(map, :approval, nil), path),
         {:ok, source} <- source(V.optional(map, :source, nil), path ++ ["source"]),
         {:ok, purpose} <- scoped_string(scope, map, :purpose, path),
         {:ok, last_reviewed} <- scoped_string(scope, map, :last_reviewed, path) do
      {:ok,
       %__MODULE__{
         owner: owner,
         tags: tags,
         lifecycle: lifecycle,
         lifecycle_reason: lifecycle_reason,
         generated_by: generated_by,
         maintainers: maintainers,
         review: review,
         approval: approval,
         source: source,
         purpose: purpose,
         last_reviewed: last_reviewed
       }}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = metadata) do
    %{
      "owner" => metadata.owner,
      "tags" => non_empty(metadata.tags),
      "lifecycle" => atom_string(metadata.lifecycle),
      "lifecycle_reason" => metadata.lifecycle_reason,
      "generated_by" => metadata.generated_by,
      "maintainers" => non_empty(metadata.maintainers),
      "review" => metadata.review,
      "approval" => metadata.approval,
      "source" => metadata.source,
      "purpose" => metadata.purpose,
      "last_reviewed" => metadata.last_reviewed
    }
    |> compact()
  end

  defp keys(:workflow), do: @workflow_keys
  defp keys(:shot), do: @shot_keys

  defp optional_lifecycle(map, path) do
    case V.optional(map, :lifecycle, nil) do
      nil -> {:ok, nil}
      value -> V.enum(value, @lifecycles, path ++ ["lifecycle"])
    end
  end

  defp generated_by(nil, _path), do: {:ok, nil}

  defp generated_by(value, path) do
    path = path ++ ["generated_by"]

    with {:ok, map} <- V.map(value, path),
         :ok <- V.known_keys(map, @generated_by_keys, path),
         :ok <- enforce_size(map, path),
         {:ok, tool} <- V.optional_non_empty_string(map, :tool, path),
         {:ok, command} <- V.optional_non_empty_string(map, :command, path),
         {:ok, version} <- V.optional_non_empty_string(map, :version, path),
         {:ok, source} <- source(V.optional(map, :source, nil), path ++ ["source"]) do
      {:ok,
       %{
         "tool" => tool,
         "command" => command,
         "version" => version,
         "source" => source
       }
       |> compact()}
    end
  end

  defp source(nil, _path), do: {:ok, nil}

  defp source(value, path) do
    with {:ok, map} <- V.map(value, path),
         :ok <- V.known_keys(map, @source_keys, path),
         :ok <- enforce_size(map, path) do
      map
      |> normalize_source(path)
    end
  end

  defp normalize_source(map, path) do
    Enum.reduce_while(@source_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case source_value(map, key, path) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp source_value(map, key, path) when key in ~w(hash digest) do
    case V.optional(map, String.to_atom(key), nil) do
      nil -> {:ok, nil}
      value -> digest(value, path ++ [key])
    end
  end

  defp source_value(map, key, path) do
    V.optional_non_empty_string(map, String.to_atom(key), path)
  end

  defp maintainers(map, path) do
    case V.optional(map, :maintainers, []) do
      nil -> {:ok, []}
      value -> V.non_empty_string_list(value, path ++ ["maintainers"])
    end
  end

  defp binding(_kind, nil, _path), do: {:ok, nil}

  defp binding(kind, value, path) do
    binding_path = path ++ [Atom.to_string(kind)]
    keys = if kind == :review, do: @review_keys, else: @approval_keys

    with {:ok, map} <- V.map(value, binding_path),
         :ok <- V.known_keys(map, keys, binding_path),
         :ok <- enforce_size(map, binding_path),
         {:ok, workflow_digest} <- required_digest(map, :workflow_digest, binding_path),
         {:ok, agent_digests} <- optional_digest_map(map, :agent_digests, binding_path),
         {:ok, loadout_digest} <- optional_digest(map, :loadout_digest, binding_path),
         {:ok, actor_key} <- actor_key(kind),
         {:ok, actor} <- V.required_non_empty_string(map, actor_key, binding_path),
         {:ok, timestamp_key} <- timestamp_key(kind),
         {:ok, timestamp} <- V.required_non_empty_string(map, timestamp_key, binding_path),
         {:ok, scope} <- required_or_optional_scope(kind, map, binding_path),
         {:ok, expires_at} <- optional_expires_at(kind, map, binding_path),
         {:ok, evidence_hash} <- optional_digest(map, :evidence_hash, binding_path) do
      {:ok,
       %{
         "workflow_digest" => workflow_digest,
         "agent_digests" => agent_digests,
         "loadout_digest" => loadout_digest,
         Atom.to_string(actor_key) => actor,
         Atom.to_string(timestamp_key) => timestamp,
         "scope" => scope,
         "expires_at" => expires_at,
         "evidence_hash" => evidence_hash
       }
       |> compact()}
    end
  end

  defp actor_key(:review), do: {:ok, :reviewer}
  defp actor_key(:approval), do: {:ok, :approver}

  defp timestamp_key(:review), do: {:ok, :reviewed_at}
  defp timestamp_key(:approval), do: {:ok, :approved_at}

  defp required_or_optional_scope(:review, map, path),
    do: V.optional_non_empty_string(map, :scope, path)

  defp required_or_optional_scope(:approval, map, path),
    do: V.required_non_empty_string(map, :scope, path)

  defp optional_expires_at(:review, _map, _path), do: {:ok, nil}

  defp optional_expires_at(:approval, map, path),
    do: V.optional_non_empty_string(map, :expires_at, path)

  defp optional_digest(map, key, path) do
    case V.optional(map, key, nil) do
      nil -> {:ok, nil}
      value -> digest(value, path ++ [Atom.to_string(key)])
    end
  end

  defp required_digest(map, key, path) do
    with {:ok, value} <- V.required(map, key, path) do
      digest(value, path ++ [Atom.to_string(key)])
    end
  end

  defp optional_digest_map(map, key, path) do
    case V.optional(map, key, nil) do
      nil -> {:ok, nil}
      value -> digest_map(value, path ++ [Atom.to_string(key)])
    end
  end

  defp digest_map(value, path) do
    with {:ok, map} <- V.map(value, path),
         :ok <- enforce_size(map, path) do
      Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        with {:ok, key} <- digest_map_key(key, path),
             {:ok, value} <- digest(value, path ++ [key]) do
          {:cont, {:ok, Map.put(acc, key, value)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp digest_map_key(key, _path) when is_binary(key) and byte_size(key) > 0, do: {:ok, key}
  defp digest_map_key(key, path) when is_atom(key), do: digest_map_key(Atom.to_string(key), path)

  defp digest_map_key(_key, path) do
    V.error(:invalid_shell, "digest map keys must be non-empty strings", path)
  end

  defp digest(value, path) when is_binary(value) do
    if Regex.match?(@digest_regex, value) do
      {:ok, value}
    else
      V.error(:invalid_shell, "expected sha256 digest", path, %{expected: "sha256:<64 hex>"})
    end
  end

  defp digest(_value, path) do
    V.error(:invalid_shell, "expected sha256 digest", path, %{expected: "sha256:<64 hex>"})
  end

  defp scoped_string(:workflow, map, :lifecycle_reason, path),
    do: V.optional_non_empty_string(map, :lifecycle_reason, path)

  defp scoped_string(:shot, map, field, path), do: V.optional_non_empty_string(map, field, path)
  defp scoped_string(:workflow, _map, _field, _path), do: {:ok, nil}

  defp enforce_size(map, path) do
    encoded = Jason.encode!(map)

    if byte_size(encoded) <= @max_encoded_bytes do
      :ok
    else
      V.error(:invalid_shell, "metadata is too large", path, %{
        max_bytes: @max_encoded_bytes,
        bytes: byte_size(encoded)
      })
    end
  end

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)

  defp non_empty([]), do: nil
  defp non_empty(value), do: value

  defp compact(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      value = compact(value)

      if empty?(value) do
        acc
      else
        Map.put(acc, to_string(key), value)
      end
    end)
  end

  defp compact(list) when is_list(list), do: Enum.map(list, &compact/1)
  defp compact(value), do: value

  defp empty?(nil), do: true
  defp empty?(map) when map == %{}, do: true
  defp empty?(_value), do: false
end
