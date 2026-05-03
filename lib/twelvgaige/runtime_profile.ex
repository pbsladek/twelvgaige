defmodule Twelvgaige.RuntimeProfile do
  @moduledoc """
  Named local runtime profiles for resource and byte-budget enforcement.

  Profiles are deliberately conservative. They describe local admission and
  retention limits, not provider-side quotas.
  """

  alias Twelvgaige.Error

  @order [:minimal, :laptop, :workstation, :server]

  @profiles %{
    minimal: %{
      limits: %{
        active_round: 1,
        active_shot: 1,
        active_shot_per_round: 1,
        llm_call: 1,
        tool_exec: 1,
        retained_bytes: 128 * 1024 * 1024
      },
      shot: %{
        max_iterations: 4,
        max_tool_calls_per_shot: 1,
        tool_max_output_bytes: 64 * 1024,
        tool_max_output_bytes_per_shot: 256 * 1024,
        tool_result_message_max_bytes: 16 * 1024,
        max_llm_message_bytes: 512 * 1024,
        max_trace_bytes: 128 * 1024
      }
    },
    laptop: %{
      limits: %{
        active_round: 1,
        active_shot: 4,
        active_shot_per_round: 3,
        llm_call: 4,
        tool_exec: 4,
        retained_bytes: 512 * 1024 * 1024
      },
      shot: %{
        max_iterations: 6,
        max_tool_calls_per_shot: 1,
        tool_max_output_bytes: 256 * 1024,
        tool_max_output_bytes_per_shot: 1024 * 1024,
        tool_result_message_max_bytes: 64 * 1024,
        max_llm_message_bytes: 2 * 1024 * 1024,
        max_trace_bytes: 512 * 1024
      }
    },
    workstation: %{
      limits: %{
        active_round: 4,
        active_shot: 8,
        active_shot_per_round: 6,
        llm_call: 8,
        tool_exec: 8,
        retained_bytes: 1024 * 1024 * 1024
      },
      shot: %{
        max_iterations: 8,
        max_tool_calls_per_shot: 2,
        tool_max_output_bytes: 512 * 1024,
        tool_max_output_bytes_per_shot: 2 * 1024 * 1024,
        tool_result_message_max_bytes: 128 * 1024,
        max_llm_message_bytes: 4 * 1024 * 1024,
        max_trace_bytes: 1024 * 1024
      }
    },
    server: %{
      limits: %{
        active_round: 16,
        active_shot: 32,
        active_shot_per_round: 12,
        llm_call: 32,
        tool_exec: 32,
        retained_bytes: 4 * 1024 * 1024 * 1024
      },
      shot: %{
        max_iterations: 10,
        max_tool_calls_per_shot: 4,
        tool_max_output_bytes: 1024 * 1024,
        tool_max_output_bytes_per_shot: 8 * 1024 * 1024,
        tool_result_message_max_bytes: 256 * 1024,
        max_llm_message_bytes: 8 * 1024 * 1024,
        max_trace_bytes: 2 * 1024 * 1024
      }
    }
  }

  @type name :: :minimal | :laptop | :workstation | :server

  @spec names() :: [name()]
  def names, do: @order

  @spec default() :: term()
  def default do
    System.get_env("TWELVGAIGE_PROFILE") ||
      Application.get_env(:twelvgaige, :resource_profile, :laptop)
  end

  @spec normalize(term()) :: {:ok, name()} | {:error, Error.t()}
  def normalize(nil), do: {:ok, :laptop}

  def normalize(profile) when is_atom(profile) do
    if Map.has_key?(@profiles, profile) do
      {:ok, profile}
    else
      invalid_profile(profile)
    end
  end

  def normalize(profile) when is_binary(profile) do
    profile
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> invalid_profile(profile)
      value -> normalize_binary(value, profile)
    end
  end

  def normalize(profile), do: invalid_profile(profile)

  @spec normalize!(term()) :: name()
  def normalize!(profile) do
    case normalize(profile) do
      {:ok, profile} -> profile
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec effective(map() | struct() | nil, keyword()) :: {:ok, name()} | {:error, Error.t()}
  def effective(policy_or_profile, opts \\ []) do
    requested =
      Keyword.get(opts, :profile) ||
        Keyword.get(opts, :resource_profile) ||
        resource_profile(policy_or_profile) ||
        default()

    with {:ok, requested} <- normalize(requested),
         {:ok, max_profile} <- max_profile(opts) do
      {:ok, min_profile(requested, max_profile)}
    end
  end

  @spec from_snapshot(term(), keyword()) :: {:ok, name()} | {:error, Error.t()}
  def from_snapshot(snapshot, _opts \\ []) do
    requested =
      value(snapshot, :resource_profile) ||
        snapshot
        |> value(:policy, %{})
        |> resource_profile() ||
        :laptop

    normalize(requested)
  end

  @spec limits(name() | String.t(), map() | keyword()) :: map()
  def limits(profile, overrides \\ %{}) do
    profile
    |> normalize!()
    |> profile_value(:limits)
    |> merge_overrides(overrides)
  end

  @spec shot_opts(name() | String.t(), keyword()) :: keyword()
  def shot_opts(profile, opts \\ []) do
    defaults =
      profile
      |> normalize!()
      |> profile_value(:shot)
      |> Map.to_list()

    Enum.reduce(defaults, opts, fn {key, value}, acc ->
      Keyword.put_new(acc, key, value)
    end)
  end

  defp max_profile(opts) do
    opts
    |> Keyword.get(
      :max_profile,
      System.get_env("TWELVGAIGE_MAX_PROFILE") ||
        Application.get_env(:twelvgaige, :max_resource_profile, :server)
    )
    |> normalize()
  end

  defp min_profile(left, right) do
    if profile_rank(left) <= profile_rank(right), do: left, else: right
  end

  defp profile_rank(profile), do: Enum.find_index(@order, &(&1 == profile)) || 0

  defp profile_value(profile, key), do: @profiles |> Map.fetch!(profile) |> Map.fetch!(key)

  defp normalize_binary(value, original) do
    case Enum.find(@order, &(Atom.to_string(&1) == value)) do
      nil -> invalid_profile(original)
      profile -> {:ok, profile}
    end
  end

  defp resource_profile(%_struct{} = value), do: Map.get(value, :resource_profile)

  defp resource_profile(%{} = value) do
    Map.get(value, :resource_profile, Map.get(value, "resource_profile"))
  end

  defp resource_profile(_value), do: nil

  defp merge_overrides(limits, overrides) when is_map(overrides) or is_list(overrides) do
    Enum.reduce(overrides, limits, fn {key, value}, acc ->
      Map.put(acc, normalize_limit_key(key), value)
    end)
  end

  defp normalize_limit_key(:running_shot_global), do: :active_shot
  defp normalize_limit_key(:running_shot_per_round), do: :active_shot_per_round
  defp normalize_limit_key(:tool_call), do: :tool_exec
  defp normalize_limit_key("active_round"), do: :active_round
  defp normalize_limit_key("active_shot"), do: :active_shot
  defp normalize_limit_key("active_shot_per_round"), do: :active_shot_per_round
  defp normalize_limit_key("running_shot_global"), do: :active_shot
  defp normalize_limit_key("running_shot_per_round"), do: :active_shot_per_round
  defp normalize_limit_key("llm_call"), do: :llm_call
  defp normalize_limit_key("tool_call"), do: :tool_exec
  defp normalize_limit_key("tool_exec"), do: :tool_exec
  defp normalize_limit_key("retained_bytes"), do: :retained_bytes
  defp normalize_limit_key(key), do: key

  defp value(map, key, default \\ nil)

  defp value(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value(_value, _key, default), do: default

  defp invalid_profile(profile) do
    {:error,
     Error.new(:input_error, :invalid_shell, "unsupported resource profile",
       details: %{
         profile: inspect(profile),
         supported_profiles: Enum.map(@order, &Atom.to_string/1)
       }
     )}
  end
end
