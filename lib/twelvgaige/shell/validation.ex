defmodule Twelvgaige.Shell.Validation do
  @moduledoc false

  @slug_regex ~r/^[a-zA-Z0-9_-]+$/
  @semver_regex ~r/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/
  @duration_regex ~r/^(\d+)(ms|s|m|h)$/

  @spec error(atom(), String.t(), [term()], map()) :: {:error, Twelvgaige.Error.t()}
  def error(reason, message, path, details \\ %{}) do
    {:error,
     Twelvgaige.Error.new(
       :compile_error,
       reason,
       message,
       retryable: false,
       safety_required: false,
       details: Map.merge(%{path: path}, details)
     )}
  end

  @spec map(term(), [term()]) :: {:ok, map()} | {:error, Twelvgaige.Error.t()}
  def map(value, _path) when is_map(value), do: {:ok, value}

  def map(_value, path) do
    error(:invalid_shell, "expected a map", path, %{expected: "map"})
  end

  @spec known_keys(map(), [atom() | String.t()], [term()]) :: :ok | {:error, Twelvgaige.Error.t()}
  def known_keys(map, allowed, path) do
    allowed = MapSet.new(Enum.map(allowed, &to_string/1))

    Enum.reduce_while(Map.keys(map), :ok, fn key, :ok ->
      with {:ok, key_string} <- key_to_string(key) do
        if MapSet.member?(allowed, key_string) do
          {:cont, :ok}
        else
          {:halt,
           error(
             :invalid_shell,
             "unknown shell field #{inspect(key_string)}",
             path ++ [key_string],
             %{
               field: key_string
             }
           )}
        end
      else
        :error ->
          {:halt,
           error(:invalid_shell, "shell field names must be strings or atoms", path, %{
             field: inspect(key)
           })}
      end
    end)
  end

  @spec key_to_string(term()) :: {:ok, String.t()} | :error
  def key_to_string(key) when is_binary(key), do: {:ok, key}
  def key_to_string(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  def key_to_string(_key), do: :error

  @spec fetch(map(), atom()) :: {:ok, term()} | :error
  def fetch(map, field) when is_atom(field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(map, string_field) -> {:ok, Map.fetch!(map, string_field)}
      Map.has_key?(map, field) -> {:ok, Map.fetch!(map, field)}
      true -> :error
    end
  end

  @spec required(map(), atom(), [term()]) :: {:ok, term()} | {:error, Twelvgaige.Error.t()}
  def required(map, field, path) do
    case fetch(map, field) do
      {:ok, nil} ->
        missing_field_error(field, path)

      {:ok, value} ->
        {:ok, value}

      :error ->
        missing_field_error(field, path)
    end
  end

  @spec optional(map(), atom(), term()) :: term()
  def optional(map, field, default) do
    case fetch(map, field) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @spec required_non_empty_string(map(), atom(), [term()]) ::
          {:ok, String.t()} | {:error, Twelvgaige.Error.t()}
  def required_non_empty_string(map, field, path) do
    with {:ok, value} <- required(map, field, path) do
      non_empty_string(value, path ++ [Atom.to_string(field)])
    end
  end

  @spec optional_non_empty_string(map(), atom(), [term()]) ::
          {:ok, String.t() | nil} | {:error, Twelvgaige.Error.t()}
  def optional_non_empty_string(map, field, path) do
    case optional(map, field, nil) do
      nil -> {:ok, nil}
      value -> non_empty_string(value, path ++ [Atom.to_string(field)])
    end
  end

  @spec non_empty_string(term(), [term()]) :: {:ok, String.t()} | {:error, Twelvgaige.Error.t()}
  def non_empty_string(value, path) when is_binary(value) do
    if String.trim(value) == "" do
      error(:invalid_shell, "expected a non-empty string", path, %{expected: "non_empty_string"})
    else
      {:ok, value}
    end
  end

  def non_empty_string(_value, path) do
    error(:invalid_shell, "expected a non-empty string", path, %{expected: "non_empty_string"})
  end

  @spec required_slug(map(), atom(), [term()]) ::
          {:ok, String.t()} | {:error, Twelvgaige.Error.t()}
  def required_slug(map, field, path) do
    with {:ok, value} <- required_non_empty_string(map, field, path) do
      slug(value, path ++ [Atom.to_string(field)])
    end
  end

  @spec slug(term(), [term()]) :: {:ok, String.t()} | {:error, Twelvgaige.Error.t()}
  def slug(value, path) when is_binary(value) do
    if Regex.match?(@slug_regex, value) do
      {:ok, value}
    else
      error(:invalid_shell, "expected an ASCII slug", path, %{expected: "ascii_slug"})
    end
  end

  def slug(_value, path),
    do: error(:invalid_shell, "expected an ASCII slug", path, %{expected: "ascii_slug"})

  @spec optional_semver(map(), atom(), [term()]) ::
          {:ok, String.t() | nil} | {:error, Twelvgaige.Error.t()}
  def optional_semver(map, field, path) do
    case optional(map, field, nil) do
      nil -> {:ok, nil}
      value -> semver(value, path ++ [Atom.to_string(field)])
    end
  end

  @spec required_semver(map(), atom(), [term()]) ::
          {:ok, String.t()} | {:error, Twelvgaige.Error.t()}
  def required_semver(map, field, path) do
    with {:ok, value} <- required_non_empty_string(map, field, path) do
      semver(value, path ++ [Atom.to_string(field)])
    end
  end

  @spec semver(term(), [term()]) :: {:ok, String.t()} | {:error, Twelvgaige.Error.t()}
  def semver(value, path) when is_binary(value) do
    if Regex.match?(@semver_regex, value) do
      {:ok, value}
    else
      error(:invalid_shell, "expected a SemVer 2.0.0 version", path, %{expected: "semver"})
    end
  end

  def semver(_value, path) do
    error(:invalid_shell, "expected a SemVer 2.0.0 version", path, %{expected: "semver"})
  end

  @spec required_enum(map(), atom(), [atom()], [term()]) ::
          {:ok, atom()} | {:error, Twelvgaige.Error.t()}
  def required_enum(map, field, allowed, path) do
    with {:ok, value} <- required(map, field, path) do
      enum(value, allowed, path ++ [Atom.to_string(field)])
    end
  end

  @spec optional_enum(map(), atom(), [atom()], atom(), [term()]) ::
          {:ok, atom()} | {:error, Twelvgaige.Error.t()}
  def optional_enum(map, field, allowed, default, path) do
    case optional(map, field, nil) do
      nil -> {:ok, default}
      value -> enum(value, allowed, path ++ [Atom.to_string(field)])
    end
  end

  @spec enum(term(), [atom()], [term()]) :: {:ok, atom()} | {:error, Twelvgaige.Error.t()}
  def enum(value, allowed, path) when is_atom(value) do
    if value in allowed do
      {:ok, value}
    else
      enum_error(allowed, path)
    end
  end

  def enum(value, allowed, path) when is_binary(value) do
    by_string = Map.new(allowed, fn item -> {Atom.to_string(item), item} end)

    case Map.fetch(by_string, value) do
      {:ok, item} -> {:ok, item}
      :error -> enum_error(allowed, path)
    end
  end

  def enum(_value, allowed, path), do: enum_error(allowed, path)

  @spec required_string_enum(map(), atom(), [String.t()], [term()]) ::
          {:ok, String.t()} | {:error, Twelvgaige.Error.t()}
  def required_string_enum(map, field, allowed, path) do
    with {:ok, value} <- required(map, field, path) do
      string_enum(value, allowed, path ++ [Atom.to_string(field)])
    end
  end

  @spec string_enum(term(), [String.t()], [term()]) ::
          {:ok, String.t()} | {:error, Twelvgaige.Error.t()}
  def string_enum(value, allowed, path) when is_binary(value) do
    if value in allowed do
      {:ok, value}
    else
      string_enum_error(allowed, path)
    end
  end

  def string_enum(value, allowed, path) when is_atom(value) do
    value
    |> Atom.to_string()
    |> string_enum(allowed, path)
  end

  def string_enum(_value, allowed, path), do: string_enum_error(allowed, path)

  @spec optional_positive_integer(map(), atom(), integer() | nil, [term()]) ::
          {:ok, integer() | nil} | {:error, Twelvgaige.Error.t()}
  def optional_positive_integer(map, field, default, path) do
    case optional(map, field, default) do
      nil -> {:ok, nil}
      value -> positive_integer(value, path ++ [Atom.to_string(field)])
    end
  end

  @spec positive_integer(term(), [term()]) ::
          {:ok, pos_integer()} | {:error, Twelvgaige.Error.t()}
  def positive_integer(value, _path) when is_integer(value) and value > 0, do: {:ok, value}

  def positive_integer(_value, path) do
    error(:invalid_shell, "expected a positive integer", path, %{expected: "positive_integer"})
  end

  @spec optional_duration_ms(map(), atom(), integer() | nil, [term()], keyword()) ::
          {:ok, integer() | nil} | {:error, Twelvgaige.Error.t()}
  def optional_duration_ms(map, field, default, path, opts \\ []) do
    case optional(map, field, default) do
      nil -> {:ok, nil}
      value -> duration_ms(value, path ++ [Atom.to_string(field)], opts)
    end
  end

  @spec duration_ms(term(), [term()], keyword()) ::
          {:ok, non_neg_integer()} | {:error, Twelvgaige.Error.t()}
  def duration_ms(value, path, opts \\ [])

  def duration_ms(value, path, opts) when is_integer(value) do
    allow_zero = Keyword.get(opts, :allow_zero, false)

    cond do
      value > 0 -> {:ok, value}
      value == 0 and allow_zero -> {:ok, value}
      true -> duration_error(path, allow_zero)
    end
  end

  def duration_ms(value, path, opts) when is_binary(value) do
    allow_zero = Keyword.get(opts, :allow_zero, false)

    with [_, amount, unit] <- Regex.run(@duration_regex, value),
         {amount, ""} <- Integer.parse(amount),
         true <- amount > 0 or (amount == 0 and allow_zero) do
      {:ok, amount * unit_multiplier(unit)}
    else
      _ -> duration_error(path, allow_zero)
    end
  end

  def duration_ms(_value, path, opts) do
    duration_error(path, Keyword.get(opts, :allow_zero, false))
  end

  @spec optional_slug_list(map(), atom(), [String.t()], [term()]) ::
          {:ok, [String.t()]} | {:error, Twelvgaige.Error.t()}
  def optional_slug_list(map, field, default, path) do
    case optional(map, field, default) do
      nil -> {:ok, default}
      value -> slug_list(value, path ++ [Atom.to_string(field)])
    end
  end

  @spec slug_list(term(), [term()]) :: {:ok, [String.t()]} | {:error, Twelvgaige.Error.t()}
  def slug_list(value, path) when is_list(value) do
    with {:ok, values} <- indexed_map(value, path, &slug/2),
         :ok <- unique(values, path) do
      {:ok, values}
    end
  end

  def slug_list(_value, path), do: error(:invalid_shell, "expected a list of ASCII slugs", path)

  @spec non_empty_string_list(term(), [term()]) ::
          {:ok, [String.t()]} | {:error, Twelvgaige.Error.t()}
  def non_empty_string_list(value, path) when is_list(value) do
    with {:ok, values} <- indexed_map(value, path, &non_empty_string/2),
         :ok <- unique(values, path) do
      {:ok, values}
    end
  end

  def non_empty_string_list(_value, path) do
    error(:invalid_shell, "expected a list of non-empty strings", path)
  end

  @spec optional_condition(map(), atom(), boolean() | String.t(), [term()]) ::
          {:ok, boolean() | String.t()} | {:error, Twelvgaige.Error.t()}
  def optional_condition(map, field, default, path) do
    case optional(map, field, default) do
      value when is_boolean(value) ->
        {:ok, value}

      value when is_binary(value) ->
        non_empty_string(value, path ++ [Atom.to_string(field)])

      _other ->
        error(
          :invalid_shell,
          "expected a boolean or condition string",
          path ++ [Atom.to_string(field)]
        )
    end
  end

  @spec enum_list(term(), [atom()], [term()]) :: {:ok, [atom()]} | {:error, Twelvgaige.Error.t()}
  def enum_list(value, allowed, path) when is_list(value) do
    with {:ok, values} <-
           indexed_map(value, path, fn item, item_path -> enum(item, allowed, item_path) end),
         :ok <- unique(values, path) do
      {:ok, values}
    end
  end

  def enum_list(_value, _allowed, path), do: error(:invalid_shell, "expected a list", path)

  @spec unique([term()], [term()]) :: :ok | {:error, Twelvgaige.Error.t()}
  def unique(values, path) do
    case first_duplicate(values) do
      nil ->
        :ok

      duplicate ->
        error(:invalid_shell, "duplicate value #{inspect(duplicate)}", path, %{
          duplicate: duplicate
        })
    end
  end

  defp first_duplicate(values) do
    Enum.reduce_while(values, MapSet.new(), fn value, seen ->
      if MapSet.member?(seen, value) do
        {:halt, value}
      else
        {:cont, MapSet.put(seen, value)}
      end
    end)
    |> case do
      %MapSet{} -> nil
      duplicate -> duplicate
    end
  end

  @spec indexed_map([term()], [term()], (term(), [term()] ->
                                           {:ok, term()} | {:error, Twelvgaige.Error.t()})) ::
          {:ok, [term()]} | {:error, Twelvgaige.Error.t()}
  def indexed_map(values, path, fun) when is_function(fun, 2) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case fun.(value, path ++ [index]) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, mapped} -> {:ok, Enum.reverse(mapped)}
      error -> error
    end
  end

  defp missing_field_error(field, path) do
    field_name = Atom.to_string(field)

    error(
      :invalid_shell,
      "missing required field #{inspect(field_name)}",
      path ++ [field_name],
      %{field: field_name}
    )
  end

  defp enum_error(allowed, path) do
    allowed = Enum.map(allowed, &Atom.to_string/1)

    error(:invalid_shell, "expected one of #{Enum.join(allowed, ", ")}", path, %{allowed: allowed})
  end

  defp string_enum_error(allowed, path) do
    error(:invalid_shell, "expected one of #{Enum.join(allowed, ", ")}", path, %{allowed: allowed})
  end

  defp duration_error(path, allow_zero) do
    expectation =
      if allow_zero do
        "duration string with units ms, s, m, or h, or zero milliseconds"
      else
        "positive duration string with units ms, s, m, or h"
      end

    error(:invalid_shell, "expected #{expectation}", path, %{expected: "duration"})
  end

  defp unit_multiplier("ms"), do: 1
  defp unit_multiplier("s"), do: 1_000
  defp unit_multiplier("m"), do: 60_000
  defp unit_multiplier("h"), do: 3_600_000
end
