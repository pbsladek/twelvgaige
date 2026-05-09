defmodule Twelvgaige.CLI.Commands.ShellLifecycle do
  @moduledoc false

  alias Twelvgaige.CLI.Commands.ShellLifecycleActions
  alias Twelvgaige.CLI.Commands.ShellMetadataCommands

  defdelegate lifecycle(action, path, args), to: ShellLifecycleActions
  defdelegate metadata_set(path, args), to: ShellMetadataCommands
  defdelegate metadata_clear(path, args), to: ShellMetadataCommands
end
