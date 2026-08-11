defmodule Twelvgaige.Lifecycle.FaultEvidence do
  @moduledoc """
  Records and validates retained evidence for the lifecycle fault matrix.

  Test processes append a case only after its restart and recovery assertions
  pass. Qualification then requires exactly one passing record for every case
  declared by `Twelvgaige.Lifecycle.FaultMatrix`.
  """

  alias Twelvgaige.Lifecycle.FaultMatrix

  @schema_version 1
  @event_environment "TWELVGAIGE_FAULT_EVIDENCE_EVENTS"
  @outcomes [:safe_resume, :validated_compensation, :needs_reconciliation]
  @outcome_names Enum.map(@outcomes, &Atom.to_string/1)

  @spec record_case(String.t(), atom(), map()) :: :ok | {:error, term()}
  def record_case(case_id, outcome, metadata \\ %{})
      when is_binary(case_id) and outcome in @outcomes and is_map(metadata) do
    case System.get_env(@event_environment) do
      nil ->
        :ok

      path ->
        event = %{
          schema_version: @schema_version,
          case_id: case_id,
          outcome: outcome,
          metadata: metadata
        }

        write_event(Path.expand(path), event)
    end
  end

  @spec compile(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def compile(events_path, evidence_path, opts \\ []) do
    with {:ok, events} <- read_events(events_path),
         :ok <- validate_events(events),
         {:ok, platform} <- platform_identity(opts),
         evidence <- evidence(events, platform),
         :ok <- publish(evidence_path, evidence) do
      {:ok, evidence}
    end
  end

  def schema_version, do: @schema_version
  def outcomes, do: @outcomes

  defp write_event(directory, event) do
    path = Path.join(directory, event.case_id <> ".json")
    encoded = [Jason.encode_to_iodata!(event, pretty: true), "\n"]

    :global.trans({__MODULE__, path}, fn ->
      with :ok <- File.mkdir_p(directory) do
        case File.write(path, encoded, [:binary, :exclusive]) do
          :ok -> File.chmod(path, 0o600)
          {:error, :eexist} -> verify_existing_event(path, event)
          {:error, reason} -> {:error, {:fault_evidence_event_write_failed, reason}}
        end
      end
    end)
  end

  defp verify_existing_event(path, event) do
    with {:ok, contents} <- File.read(path),
         {:ok, existing} <- Jason.decode(contents),
         {:ok, expected} <- event |> Jason.encode!() |> Jason.decode() do
      if existing == expected,
        do: :ok,
        else: {:error, {:fault_evidence_case_conflict, event.case_id}}
    end
  end

  defp read_events(path) do
    if File.dir?(path) do
      path
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn event_path, {:ok, events} ->
        case event_path |> File.read() |> decode_event() do
          {:ok, event} -> {:cont, {:ok, [event | events]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, events} -> {:ok, Enum.reverse(events)}
        {:error, _reason} = error -> error
      end
    else
      {:error, {:fault_evidence_events_unreadable, :enoent}}
    end
  end

  defp decode_event({:ok, contents}) do
    case Jason.decode(contents) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, {:fault_evidence_event_invalid, reason}}
    end
  end

  defp decode_event({:error, reason}), do: {:error, {:fault_evidence_events_unreadable, reason}}

  defp validate_events(events) do
    expected = FaultMatrix.case_ids()
    ids = Enum.map(events, &Map.get(&1, "case_id"))
    observed = MapSet.new(ids)
    duplicates = ids -- Enum.uniq(ids)

    invalid =
      Enum.reject(events, fn event ->
        Map.get(event, "schema_version") == @schema_version and
          Map.get(event, "outcome") in @outcome_names and
          is_map(Map.get(event, "metadata")) and
          MapSet.member?(expected, Map.get(event, "case_id"))
      end)

    cond do
      invalid != [] ->
        {:error, {:fault_evidence_events_invalid, invalid}}

      duplicates != [] ->
        {:error, {:fault_evidence_cases_duplicate, Enum.uniq(duplicates) |> Enum.sort()}}

      observed != expected ->
        {:error,
         {:fault_evidence_cases_incomplete,
          %{
            missing: MapSet.difference(expected, observed) |> Enum.sort(),
            unknown: MapSet.difference(observed, expected) |> Enum.sort()
          }}}

      true ->
        :ok
    end
  end

  defp platform_identity(opts) do
    git_binary = Keyword.get(opts, :git_binary, System.find_executable("git") || "git")

    case System.cmd(git_binary, ["--version"], stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
      {version, 0} ->
        {family, name} = :os.type()

        {:ok,
         %{
           os: "#{family}-#{name}",
           architecture: :erlang.system_info(:system_architecture) |> List.to_string(),
           otp: System.otp_release(),
           elixir: System.version(),
           git: String.trim(version)
         }}

      {output, status} ->
        {:error, {:fault_evidence_git_unavailable, status, String.trim(output)}}
    end
  end

  defp evidence(events, platform) do
    cases =
      events
      |> Enum.sort_by(& &1["case_id"])
      |> Enum.map(fn event ->
        %{
          case_id: event["case_id"],
          outcome: event["outcome"],
          metadata: event["metadata"]
        }
      end)

    %{
      schema: "twelvgaige.lifecycle-fault-evidence",
      schema_version: @schema_version,
      matrix_schema_version: FaultMatrix.schema_version(),
      qualified: true,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      platform: platform,
      case_count: length(cases),
      cases: cases
    }
  end

  defp publish(path, evidence) do
    path = Path.expand(path)
    staging = path <> ".staging"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <-
           File.write(staging, [Jason.encode_to_iodata!(evidence, pretty: true), "\n"], [
             :binary,
             :exclusive
           ]),
         :ok <- File.chmod(staging, 0o600),
         :ok <- File.rename(staging, path) do
      :ok
    else
      {:error, :eexist} ->
        _ = File.rm(staging)
        publish(path, evidence)

      {:error, reason} ->
        _ = File.rm(staging)
        {:error, {:fault_evidence_publish_failed, reason}}
    end
  end
end
