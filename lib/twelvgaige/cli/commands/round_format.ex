defmodule Twelvgaige.CLI.Commands.RoundFormat do
  @moduledoc false

  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Shot

  import Twelvgaige.CLI.CommandHelpers, only: [encode_line: 1, value: 2]

  def snapshot(%Snapshot{} = snapshot, :json) do
    snapshot
    |> Snapshot.to_map()
    |> encode_line()
  end

  def snapshot(%Snapshot{} = snapshot, :human) do
    shot_lines =
      snapshot.shots
      |> Enum.map(fn %Shot.State{} = shot -> "  - #{shot.id} [#{shot.status}]" end)
      |> Enum.join("\n")

    """
    Round:  #{snapshot.id}
    Shell:  #{snapshot.shell_id} #{snapshot.shell_version}
    Status: #{snapshot.status}
    Shots:
    #{shot_lines}
    """
  end

  def detached_round(round_id, :json), do: encode_line(%{id: round_id, status: "queued"})
  def detached_round(round_id, :human), do: "Round queued: #{round_id}\n"

  def round_list(rounds, :json) do
    rounds
    |> Enum.map(&Snapshot.to_map/1)
    |> encode_line()
  end

  def round_list([], :human), do: "No rounds.\n"

  def round_list(rounds, :human) do
    rows =
      rounds
      |> Enum.map(fn %Snapshot{} = snapshot ->
        "#{snapshot.id}  #{snapshot.shell_id}  #{snapshot.status}"
      end)
      |> Enum.join("\n")

    rows <> "\n"
  end

  def events([], :human), do: "No events.\n"
  def events([], :ndjson), do: ""

  def events(events, :ndjson) do
    events
    |> Enum.map(fn %Event{} = event -> event |> Event.to_map() |> Jason.encode!() end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  def events(events, :human) do
    events
    |> Enum.map(fn %Event{} = event ->
      status = value(event.payload, :status)
      detail = if status, do: " status=#{status}", else: ""
      "##{event.seq} #{event.event_type}#{detail}"
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end
end
