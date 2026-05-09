defmodule Twelvgaige.CLI.Commands.ShellCreate do
  @moduledoc false

  alias Twelvgaige.CLI.Commands.ShellDraft
  alias Twelvgaige.CLI.Commands.ShellNew

  defdelegate new(id, args), to: ShellNew
  defdelegate draft(args), to: ShellDraft
end
