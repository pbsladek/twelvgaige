defmodule Twelvgaige.CLI.Commands.Round do
  @moduledoc false

  alias Twelvgaige.CLI.Commands.RoundQuery
  alias Twelvgaige.CLI.Commands.RoundRun

  defdelegate run(path, args), to: RoundRun
  defdelegate list(args), to: RoundQuery
  defdelegate show(round_id, args), to: RoundQuery
  defdelegate watch(round_id, args), to: RoundQuery
  defdelegate stream_watch(round_id, args, write), to: RoundQuery
end
