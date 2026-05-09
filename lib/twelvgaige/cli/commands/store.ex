defmodule Twelvgaige.CLI.Commands.Store do
  @moduledoc false

  alias Twelvgaige.CLI.Commands.StoreBackupRestore
  alias Twelvgaige.CLI.Commands.StoreSecurity

  defdelegate backup(destination, args), to: StoreBackupRestore
  defdelegate restore(source, destination, args), to: StoreBackupRestore
  defdelegate migrate_sqlcipher(args), to: StoreSecurity
  defdelegate rewrap_envelope(path, args), to: StoreSecurity
end
