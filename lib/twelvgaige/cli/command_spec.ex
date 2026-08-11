defmodule Twelvgaige.CLI.CommandSpec do
  @moduledoc """
  The typed public command tree shared by dispatch, help validation, and shell
  completion.

  `Twelvgaige.CLI.Usage` supplies the human-readable invocation grammar. This
  module compiles that grammar into exact command paths, typed options,
  defaults, conflicts, output schemas, control-plane requirements, and
  authority metadata. Dispatch validates option spelling, values, and
  conflicts against this model before a command-specific parser runs.
  """

  alias Twelvgaige.CLI.ResultEnvelope
  alias Twelvgaige.CLI.Usage

  defmodule Option do
    @moduledoc false

    @enforce_keys [:name, :type, :required?, :repeatable?, :default, :conflicts]
    defstruct [:name, :type, :required?, :repeatable?, :default, :conflicts]

    @type value_type ::
            :boolean
            | :string
            | :path
            | :integer
            | :duration
            | :timestamp
            | :environment_name
            | :json
            | :digest
            | {:enum, [String.t()]}

    @type t :: %__MODULE__{
            name: String.t(),
            type: value_type(),
            required?: boolean(),
            repeatable?: boolean(),
            default: term(),
            conflicts: [String.t()]
          }
  end

  defmodule Output do
    @moduledoc false

    @enforce_keys [:formats, :result_schema, :event_schema, :schema_version]
    defstruct [:formats, :result_schema, :event_schema, :schema_version]

    @type format :: :human | :json | :ndjson | :checkpoint | :text | :yaml | :toml | :mermaid
    @type t :: %__MODULE__{
            formats: [format()],
            result_schema: String.t() | nil,
            event_schema: String.t() | nil,
            schema_version: pos_integer() | nil
          }
  end

  @enforce_keys [:path, :usages, :authority, :daemon, :options, :constraints, :output]
  defstruct [:path, :usages, :authority, :daemon, :options, :constraints, :output, hidden?: false]

  @type authority :: :read_only | :conditional_write | :managed_write | :runtime_control
  @type daemon_requirement :: :none | :required | :starts_daemon
  @type t :: %__MODULE__{
          path: [String.t()],
          usages: [String.t()],
          authority: authority(),
          daemon: daemon_requirement(),
          options: [Option.t()],
          constraints: [map()],
          output: Output.t(),
          hidden?: boolean()
        }

  @global_options [
    %{
      name: "--quiet",
      type: :boolean,
      required?: false,
      repeatable?: false,
      default: false,
      conflicts: ["--verbose"]
    },
    %{
      name: "--verbose",
      type: :boolean,
      required?: false,
      repeatable?: false,
      default: false,
      conflicts: ["--quiet"]
    },
    %{
      name: "--color",
      type: {:enum, ~w(auto always never)},
      required?: false,
      repeatable?: false,
      default: "auto",
      conflicts: []
    },
    %{
      name: "--no-color",
      type: :boolean,
      required?: false,
      repeatable?: false,
      default: false,
      conflicts: []
    }
  ]

  @option_aliases [
    %{
      alias: "--no-color",
      canonical: "--color never",
      deprecated?: false,
      remove_in: nil
    },
    %{
      alias: "--task-file",
      canonical: "positional task file",
      deprecated?: true,
      remove_in: "1.0.0"
    }
  ]

  @local_top_levels ~w(audit completion crypto doctor init repo shell shot store support task version)
  @conditional_top_levels ~w(init shell shot support)

  @managed_write_paths MapSet.new([
                         ~w(store backup),
                         ~w(store restore),
                         ~w(store migrate-sqlcipher),
                         ~w(store rewrap-envelope),
                         ~w(operations audit checkpoint),
                         ~w(operations audit export),
                         ~w(operations store backup),
                         ~w(operations store restore),
                         ~w(operations retention run),
                         ~w(operations artifact rotate),
                         ~w(session start),
                         ~w(session retry),
                         ~w(workspace retention run)
                       ])

  @runtime_control_paths MapSet.new([
                           ~w(daemon serve),
                           ~w(daemon stop),
                           ~w(daemon token rotate),
                           ~w(round run),
                           ~w(round approve),
                           ~w(round reject),
                           ~w(round cancel),
                           ~w(session attach),
                           ~w(session cancel),
                           ~w(session takeover),
                           ~w(session revoke),
                           ~w(sandbox reconcile)
                         ])

  @conditional_paths MapSet.new([
                       ~w(doctor),
                       ~w(init),
                       ~w(sandbox setup),
                       ~w(session apply),
                       ~w(session export),
                       ~w(session plan),
                       ~w(support bundle),
                       ~w(workspace apply),
                       ~w(workspace cleanup),
                       ~w(workspace export),
                       ~w(workspace reconcile),
                       ~w(workspace review cleanup)
                     ])

  @local_paths MapSet.new([
                 ~w(daemon paths),
                 ~w(daemon serve),
                 ~w(sandbox setup),
                 ~w(session plan)
               ])

  @hidden_specs [
    %{
      path: ~w(completion candidates),
      usages: [],
      authority: :read_only,
      daemon: :none,
      options: [
        %{
          name: "--current",
          type: :string,
          required?: false,
          repeatable?: false,
          default: "",
          conflicts: []
        },
        %{
          name: "--root",
          type: :path,
          required?: false,
          repeatable?: false,
          default: :unset,
          conflicts: []
        },
        %{
          name: "--data-root",
          type: :path,
          required?: false,
          repeatable?: false,
          default: :unset,
          conflicts: []
        },
        %{
          name: "--word",
          type: :string,
          required?: false,
          repeatable?: true,
          default: :unset,
          conflicts: []
        }
      ],
      constraints: [],
      output: %{
        formats: [:text],
        result_schema: nil,
        event_schema: nil,
        schema_version: nil
      },
      hidden?: true
    }
  ]

  @option_pattern ~r/--[a-z][a-z0-9-]*/
  @value_pattern ~r/^(?:=|\s+)(?!--)(<[^>]+>|[[:alnum:]_.:-]+(?:\|[[:alnum:]_.:-]+)*)/u

  @saved_plan_request_options ~w(
    --request-id --profile --auth-profile --runtime --repo --base-ref --task --task-file
    --source --include-untracked --include-ignored --sandbox --network --unrestricted-network
    --allow-path --read-only --timeout --budget-tokens --budget-cost-micros
    --budget-tool-calls
  )

  @conflict_pairs [
                    {"--check", "--write"},
                    {"--before", "--after"},
                    {"--task", "--task-file"},
                    {"--network", "--unrestricted-network"}
                  ] ++ Enum.map(@saved_plan_request_options, &{"--plan", &1})

  @repeatable_options ~w(--allow-path --agent-shell --word)

  @session_authority_options ~w(
    --profile --auth-profile --runtime --repo --base-ref --source
    --include-untracked --include-ignored --sandbox --network
    --unrestricted-network --allow-path --read-only --timeout
    --budget-tokens --budget-cost-micros --budget-tool-calls
  )

  @control_plane_option_paths MapSet.new([
                                ~w(support bundle),
                                ~w(session start),
                                ~w(session plan),
                                ~w(session watch),
                                ~w(session review),
                                ~w(session retry),
                                ~w(session export),
                                ~w(session apply),
                                ~w(session list),
                                ~w(session show),
                                ~w(session attach),
                                ~w(session takeover),
                                ~w(session cancel),
                                ~w(session revoke),
                                ~w(sandbox health),
                                ~w(sandbox reconcile),
                                ~w(operation show)
                              ])

  @default_overrides %{
    {~w(repo inspect), "--repo"} => ".",
    {~w(repo inspect), "--base-ref"} => "HEAD",
    {~w(session start), "--runtime"} => "codex",
    {~w(session start), "--repo"} => ".",
    {~w(session start), "--base-ref"} => "HEAD",
    {~w(session start), "--source"} => "committed",
    {~w(session start), "--sandbox"} => "podman",
    {~w(session start), "--network"} => "broker-only",
    {~w(session start), "--timeout"} => "45m",
    {~w(session start), "--budget-tokens"} => 80_000,
    {~w(session start), "--budget-cost-micros"} => 25_000_000,
    {~w(session start), "--budget-tool-calls"} => 1_000,
    {~w(session start), "--follow-timeout-ms"} => 3_600_000,
    {~w(session start), "--poll-ms"} => 1_000,
    {~w(session plan), "--runtime"} => "codex",
    {~w(session plan), "--repo"} => ".",
    {~w(session plan), "--base-ref"} => "HEAD",
    {~w(session plan), "--source"} => "committed",
    {~w(session plan), "--sandbox"} => "podman",
    {~w(session plan), "--network"} => "broker-only",
    {~w(session plan), "--timeout"} => "45m",
    {~w(session plan), "--budget-tokens"} => 80_000,
    {~w(session plan), "--budget-cost-micros"} => 25_000_000,
    {~w(session plan), "--budget-tool-calls"} => 1_000,
    {~w(session watch), "--timeout-ms"} => 3_600_000,
    {~w(session watch), "--poll-ms"} => 1_000,
    {~w(workspace apply), "--target"} => "review-worktree",
    {~w(session apply), "--target"} => "review-worktree",
    {~w(workspace reconcile), "--action"} => "quarantine",
    {~w(sandbox setup), "--backend"} => "podman",
    {~w(sandbox setup), "--machine"} => "twelvgaige",
    {~w(sandbox setup), "--cpus"} => 4,
    {~w(sandbox setup), "--memory-mib"} => 6_144,
    {~w(sandbox setup), "--disk-gib"} => 64,
    {~w(sandbox setup), "--timeout-ms"} => 1_800_000,
    {~w(shell new), "--scaffold"} => "single-shot",
    {~w(shell new), "--format"} => "yaml",
    {~w(shell draft), "--format"} => "yaml",
    {~w(shell normalize), "--format"} => "json",
    {~w(shell graph), "--format"} => "text",
    {~w(shell admit), "--policy"} => "manual"
  }

  @type_overrides %{
    {~w(shell new), "--scaffold"} => :string
  }

  @spec all() :: [t()]
  def all do
    usages_by_path =
      Usage.command_usages()
      |> Enum.reject(&(&1 == "twelvgaige --help"))
      |> Enum.group_by(&path_from_usage/1)
      |> Enum.reject(fn {path, _usages} -> path == [] end)
      |> Map.new()

    public =
      usages_by_path
      |> Enum.map(fn {path, usages} ->
        usages = Enum.sort(usages)
        options = options(path, usages, usages_by_path)

        %__MODULE__{
          path: path,
          usages: usages,
          authority: authority(path),
          daemon: daemon_requirement(path),
          options: options,
          constraints: constraints(path, options),
          output: output(path, options)
        }
      end)

    hidden = Enum.map(@hidden_specs, &hidden_spec/1)
    Enum.sort_by(public ++ hidden, & &1.path)
  end

  @spec public() :: [t()]
  def public, do: Enum.reject(all(), & &1.hidden?)

  @spec resolve([String.t()]) :: {:ok, t() | :root} | {:error, :unknown_command}
  def resolve([]), do: {:ok, :root}
  def resolve([arg]) when arg in ["--help", "-h"], do: {:ok, :root}

  def resolve(args) when is_list(args) do
    all()
    |> Enum.sort_by(&length(&1.path), :desc)
    |> Enum.find(&prefix?(args, &1.path))
    |> case do
      nil -> {:error, :unknown_command}
      spec -> {:ok, spec}
    end
  end

  @spec children([String.t()]) :: [String.t()]
  def children(parent \\ []) do
    depth = length(parent)

    public()
    |> Enum.filter(&(Enum.take(&1.path, depth) == parent and length(&1.path) > depth))
    |> Enum.map(&Enum.at(&1.path, depth))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec enums() :: %{atom() => [String.t()]}
  def enums do
    %{
      format: enum_values(~w(session start), "--format"),
      network: enum_values(~w(session start), "--network"),
      sandbox_backend: enum_values(~w(session start), "--sandbox"),
      source_mode: enum_values(~w(session start), "--source")
    }
  end

  @spec enum_values([String.t()], String.t()) :: [String.t()]
  def enum_values(path, name) do
    with {:ok, spec} <- resolve(path),
         {:ok, %Option{type: {:enum, values}}} <- option(spec, name) do
      values
    else
      _missing -> []
    end
  end

  @spec global_options() :: [Option.t()]
  def global_options, do: Enum.map(@global_options, &struct!(Option, &1))

  @spec global_option(String.t()) :: {:ok, Option.t()} | :error
  def global_option(name), do: Enum.find_value(global_options(), :error, &option_match(&1, name))

  @spec option_aliases() :: [map()]
  def option_aliases, do: @option_aliases

  @spec option(t(), String.t()) :: {:ok, Option.t()} | :error
  def option(%__MODULE__{} = spec, name),
    do: Enum.find_value(spec.options, :error, &option_match(&1, name))

  @spec validate(t(), [String.t()]) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = spec, args) when is_list(args) do
    command_args = Enum.drop(args, length(spec.path))
    options = Map.new(spec.options, &{&1.name, &1})

    with {:ok, seen} <- validate_tokens(command_args, options, %{}, :typed),
         :ok <- validate_required(spec, seen),
         :ok <- validate_constraints(spec.constraints, seen) do
      :ok
    end
  end

  @doc "Validates only option spelling and arity before the compatibility parser runs."
  @spec validate_shape(t(), [String.t()]) :: :ok | {:error, term()}
  def validate_shape(%__MODULE__{} = spec, args) when is_list(args) do
    command_args = Enum.drop(args, length(spec.path))
    options = Map.new(spec.options, &{&1.name, &1})

    case validate_tokens(command_args, options, %{}, :shape) do
      {:ok, _seen} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Materializes non-generated defaults for a validated invocation."
  @spec apply_defaults(t(), [String.t()]) :: [String.t()]
  def apply_defaults(%__MODULE__{} = spec, args) when is_list(args) do
    command_args = Enum.drop(args, length(spec.path))
    options = Map.new(spec.options, &{&1.name, &1})
    {:ok, seen} = validate_tokens(command_args, options, %{}, :shape)

    defaults =
      Enum.flat_map(spec.options, fn option ->
        cond do
          Map.has_key?(seen, option.name) -> []
          Enum.any?(option.conflicts, &Map.has_key?(seen, &1)) -> []
          option.default in [:unset, :generated, false, nil] -> []
          option.type == :boolean and option.default == true -> [option.name]
          true -> [option.name, to_string(option.default)]
        end
      end)

    args ++ defaults
  end

  @spec deprecations([String.t()]) :: [map()]
  def deprecations(args) do
    Enum.filter(@option_aliases, fn alias_spec ->
      alias_spec.deprecated? and Enum.member?(args, alias_spec.alias)
    end)
  end

  @spec path_from_usage(String.t()) :: [String.t()]
  def path_from_usage("twelvgaige " <> invocation) do
    invocation
    |> String.split()
    |> Enum.take_while(&command_token?/1)
  end

  defp command_token?(token) do
    not String.starts_with?(token, ["-", "<", "[", "("])
  end

  defp prefix?(args, path), do: Enum.take(args, length(path)) == path

  defp option_match(%Option{name: name} = option, name), do: {:ok, option}
  defp option_match(_option, _name), do: false

  defp hidden_spec(attrs) do
    attrs =
      attrs
      |> Map.update!(:options, &Enum.map(&1, fn option -> struct!(Option, option) end))
      |> Map.update!(:output, &struct!(Output, &1))

    struct!(__MODULE__, attrs)
  end

  defp options(path, usages, usages_by_path) do
    occurrences =
      Enum.flat_map(usages, &option_occurrences/1) ++
        inherited_option_occurrences(path, usages_by_path)

    path
    |> parsed_options(usages, occurrences)
    |> add_control_plane_options(path)
    |> Enum.sort_by(& &1.name)
  end

  defp inherited_option_occurrences(path, usages_by_path)
       when path in [~w(session plan), ~w(task validate)] do
    usages_by_path
    |> Map.fetch!(~w(session start))
    |> Enum.flat_map(&option_occurrences/1)
    |> Enum.filter(&(&1.name in @session_authority_options))
    |> Enum.map(&%{&1 | required?: false, usage: List.first(Map.fetch!(usages_by_path, path))})
  end

  defp inherited_option_occurrences(_path, _usages_by_path), do: []

  defp parsed_options(path, usages, occurrences) do
    occurrences
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, matching} ->
      type =
        Map.get(@type_overrides, {path, name}) || matching |> Enum.map(& &1.type) |> merge_types()

      %Option{
        name: name,
        type: type,
        required?: required_option?(name, matching, usages),
        repeatable?: name in @repeatable_options,
        default: option_default(path, name, type),
        conflicts: conflicts_for(name, occurrences)
      }
    end)
  end

  defp add_control_plane_options(options, path) do
    if control_plane_options?(path) do
      options
      |> add_option(%Option{
        name: "--runtime-dir",
        type: :path,
        required?: false,
        repeatable?: false,
        default: :unset,
        conflicts: []
      })
      |> add_option(%Option{
        name: "--endpoint",
        type: :path,
        required?: false,
        repeatable?: false,
        default: :unset,
        conflicts: []
      })
    else
      options
    end
  end

  defp control_plane_options?(["workspace" | _rest]), do: true
  defp control_plane_options?(["operations" | _rest]), do: true
  defp control_plane_options?(path), do: MapSet.member?(@control_plane_option_paths, path)

  defp add_option(options, %Option{name: name} = option) do
    if Enum.any?(options, &(&1.name == name)), do: options, else: [option | options]
  end

  defp option_occurrences(usage) do
    Regex.scan(@option_pattern, usage, return: :index)
    |> Enum.map(fn [{offset, length}] ->
      name = binary_part(usage, offset, length)
      tail_offset = offset + length
      tail = binary_part(usage, tail_offset, byte_size(usage) - tail_offset)
      value = option_value(tail)

      %{
        name: name,
        type: option_type(value),
        required?: option_required_at?(usage, offset),
        usage: usage
      }
    end)
  end

  defp option_value(tail) do
    case Regex.run(@value_pattern, tail, capture: :all_but_first) do
      [value] -> value
      _missing -> nil
    end
  end

  defp option_type(nil), do: :boolean

  defp option_type("<" <> value) do
    value = String.trim_trailing(value, ">")

    cond do
      path_placeholder?(value) -> :path
      integer_placeholder?(value) -> :integer
      String.contains?(value, "duration") -> :duration
      String.contains?(value, "timestamp") -> :timestamp
      String.contains?(value, "env") -> :environment_name
      String.contains?(value, "json") -> :json
      String.contains?(value, ["sha256", "digest", "hash"]) -> :digest
      enum_placeholder?(value) -> {:enum, String.split(value, "|")}
      true -> :string
    end
  end

  defp option_type(value) do
    {:enum, value |> String.split("|") |> Enum.uniq()}
  end

  defp path_placeholder?(value) do
    String.contains?(value, [
      "path",
      "file",
      "directory",
      "root",
      "plaintext.db",
      "encrypted.db",
      "envelope.json",
      "backup.json",
      "task.md",
      "task.yaml"
    ])
  end

  defp integer_placeholder?(value) do
    String.contains?(value, [
      "count",
      "bytes",
      "mib",
      "gib",
      "epoch",
      "seq",
      "limit",
      "milliseconds",
      "ms",
      "micros"
    ])
  end

  defp enum_placeholder?(value) do
    parts = String.split(value, "|")
    length(parts) > 1 and Enum.all?(parts, &Regex.match?(~r/^[a-z][a-z0-9-]*$/, &1))
  end

  defp option_required_at?(usage, offset) do
    prefix = binary_part(usage, 0, offset)
    square_depth = count(prefix, "[") - count(prefix, "]")
    angle_depth = count(prefix, "<") - count(prefix, ">")
    not in_alternative_group?(usage, prefix, offset) and square_depth == 0 and angle_depth == 0
  end

  defp in_alternative_group?(usage, prefix, offset) do
    case :binary.matches(prefix, "(") |> List.last() do
      nil ->
        false

      {open, _length} ->
        prefix_suffix = binary_part(prefix, open, byte_size(prefix) - open)
        tail = binary_part(usage, offset, byte_size(usage) - offset)

        case :binary.match(tail, ")") do
          :nomatch ->
            false

          {close, _length} ->
            group = prefix_suffix <> binary_part(tail, 0, close + 1)
            not String.contains?(prefix_suffix, ")") and String.contains?(group, "|")
        end
    end
  end

  defp count(value, token), do: length(:binary.matches(value, token))

  defp required_option?(name, matching, usages) do
    Enum.all?(usages, fn usage ->
      Enum.any?(matching, &(&1.usage == usage and &1.required? and &1.name == name))
    end)
  end

  defp merge_types(types) do
    types
    |> Enum.uniq()
    |> case do
      [type] -> type
      mixed -> merge_mixed_types(mixed)
    end
  end

  defp merge_mixed_types(types) do
    enum_values =
      types
      |> Enum.flat_map(fn
        {:enum, values} -> values
        _type -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    cond do
      enum_values != [] and Enum.all?(types, &match?({:enum, _}, &1)) ->
        {:enum, enum_values}

      :string in types ->
        :string

      true ->
        raise "incompatible option types in CLI usage: #{inspect(types)}"
    end
  end

  defp option_default(path, name, type) do
    case Map.fetch(@default_overrides, {path, name}) do
      {:ok, default} -> default
      :error when path == ~w(task validate) -> option_default(~w(session plan), name, type)
      :error -> inferred_default(name, type)
    end
  end

  defp inferred_default("--format", _type), do: "human"

  defp inferred_default(name, _type) when name in ["--request-id", "--cancel-request-id"],
    do: :generated

  defp inferred_default(_name, :boolean), do: false
  defp inferred_default(_name, _type), do: :unset

  defp conflicts_for(name, occurrences) do
    names = MapSet.new(occurrences, & &1.name)

    Enum.flat_map(@conflict_pairs, fn
      {^name, other} -> if(MapSet.member?(names, other), do: [other], else: [])
      {other, ^name} -> if(MapSet.member?(names, other), do: [other], else: [])
      _pair -> []
    end)
    |> Enum.sort()
  end

  defp constraints(path, options) do
    conflicts =
      options
      |> Enum.flat_map(fn option ->
        Enum.map(option.conflicts, fn other ->
          %{kind: :mutually_exclusive, options: Enum.sort([option.name, other])}
        end)
      end)
      |> Enum.uniq()

    path_constraints(path) ++ conflicts
  end

  defp path_constraints(~w(shell impact)),
    do: [%{kind: :exactly_one, options: ~w(--agent --template --tool)}]

  defp path_constraints(~w(shot move)),
    do: [%{kind: :exactly_one, options: ~w(--after --before)}]

  defp path_constraints(~w(shot remove)),
    do: [%{kind: :requires, option: "--yes", required_option: "--cascade"}]

  defp path_constraints(_path), do: []

  defp output(path, options) do
    formats = output_formats(path, options)

    %Output{
      formats: formats,
      result_schema: if(:json in formats, do: ResultEnvelope.result_schema(), else: nil),
      event_schema: if(:ndjson in formats, do: ResultEnvelope.event_schema(), else: nil),
      schema_version:
        if(Enum.any?(formats, &(&1 in [:json, :ndjson])),
          do: ResultEnvelope.schema_version(),
          else: nil
        )
    }
  end

  defp output_formats(~w(completion), _options), do: [:text]
  defp output_formats(~w(version), _options), do: [:human]

  defp output_formats(_path, options) do
    case Enum.find(options, &(&1.name == "--format")) do
      %Option{type: {:enum, values}} -> Enum.map(values, &String.to_atom/1)
      _missing -> [:human]
    end
  end

  defp validate_tokens([], _options, seen, _mode), do: {:ok, seen}

  defp validate_tokens(["--" <> _rest = name | tail], options, seen, mode) do
    case Map.fetch(options, name) do
      {:ok, %Option{type: :boolean}} ->
        validate_tokens(tail, options, Map.put(seen, name, true), mode)

      {:ok, %Option{} = option} ->
        case tail do
          [value | rest] ->
            with :ok <- validate_option_value(option, value, mode) do
              validate_tokens(rest, options, Map.put(seen, name, true), mode)
            end

          [] ->
            {:error, {:missing_option_value, name}}
        end

      :error ->
        {:error, {:unknown_option, name}}
    end
  end

  defp validate_tokens([_positional | rest], options, seen, mode),
    do: validate_tokens(rest, options, seen, mode)

  defp validate_option_value(_option, _value, :shape), do: :ok

  defp validate_option_value(%Option{type: {:enum, values}, name: name}, value, :typed) do
    if value in values,
      do: :ok,
      else: {:error, {:invalid_option_value, name, value, values}}
  end

  defp validate_option_value(%Option{type: :integer, name: name}, value, :typed) do
    case Integer.parse(value) do
      {_integer, ""} -> :ok
      _invalid -> {:error, {:invalid_option_value, name, value, :integer}}
    end
  end

  defp validate_option_value(%Option{type: :duration, name: name}, value, :typed) do
    case Regex.run(~r/^(\d+)(ms|s|m|h)$/, value, capture: :all_but_first) do
      [amount, _unit] when amount != "0" -> :ok
      _invalid -> {:error, {:invalid_option_value, name, value, :duration}}
    end
  end

  defp validate_option_value(%Option{type: :timestamp, name: name}, value, :typed) do
    case DateTime.from_iso8601(value) do
      {:ok, _timestamp, _offset} -> :ok
      _invalid -> {:error, {:invalid_option_value, name, value, :timestamp}}
    end
  end

  defp validate_option_value(%Option{type: :environment_name, name: name}, value, :typed) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, value),
      do: :ok,
      else: {:error, {:invalid_option_value, name, value, :environment_name}}
  end

  defp validate_option_value(%Option{type: :json, name: name}, value, :typed) do
    case Jason.decode(value) do
      {:ok, _decoded} -> :ok
      {:error, _reason} -> {:error, {:invalid_option_value, name, value, :json}}
    end
  end

  defp validate_option_value(%Option{type: :digest, name: name}, value, :typed) do
    if Regex.match?(~r/^sha256:[0-9a-f]{64}$/, value),
      do: :ok,
      else: {:error, {:invalid_option_value, name, value, :digest}}
  end

  defp validate_option_value(_option, _value, :typed), do: :ok

  defp validate_required(spec, seen) do
    required = Enum.filter(spec.options, & &1.required?)

    usage_order =
      spec.usages
      |> Enum.flat_map(&option_occurrences/1)
      |> Enum.map(& &1.name)
      |> Enum.uniq()

    ordered =
      Enum.sort_by(required, fn option ->
        Enum.find_index(usage_order, &(&1 == option.name)) || length(usage_order)
      end)

    case Enum.find(ordered, &(not Map.has_key?(seen, &1.name))) do
      nil -> :ok
      %Option{name: name} -> {:error, {:required_option_missing, name}}
    end
  end

  defp validate_constraints(constraints, seen) do
    Enum.reduce_while(constraints, :ok, fn
      %{kind: :mutually_exclusive, options: [left, right]}, :ok ->
        if Map.has_key?(seen, left) and Map.has_key?(seen, right),
          do: {:halt, {:error, {:option_conflict, left, right}}},
          else: {:cont, :ok}

      %{kind: :exactly_one, options: options}, :ok ->
        present = Enum.count(options, &Map.has_key?(seen, &1))

        if present == 1,
          do: {:cont, :ok},
          else: {:halt, {:error, {:exactly_one_option_required, options}}}

      %{kind: :requires, option: option, required_option: required}, :ok ->
        if Map.has_key?(seen, option) and not Map.has_key?(seen, required),
          do: {:halt, {:error, {:option_requires, option, required}}},
          else: {:cont, :ok}

      _constraint, :ok ->
        {:cont, :ok}
    end)
  end

  defp authority(path) do
    cond do
      MapSet.member?(@runtime_control_paths, path) -> :runtime_control
      MapSet.member?(@managed_write_paths, path) -> :managed_write
      MapSet.member?(@conditional_paths, path) -> :conditional_write
      List.first(path) in @conditional_top_levels -> :conditional_write
      true -> :read_only
    end
  end

  defp daemon_requirement(["daemon", "serve"]), do: :starts_daemon

  defp daemon_requirement(path) do
    cond do
      MapSet.member?(@local_paths, path) -> :none
      List.first(path) in @local_top_levels -> :none
      true -> :required
    end
  end
end
