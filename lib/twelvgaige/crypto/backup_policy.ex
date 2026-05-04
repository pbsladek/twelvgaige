defmodule Twelvgaige.Crypto.BackupPolicy do
  @moduledoc """
  Backup/export policy checks for encrypted-store phases.

  This module does not copy databases yet. It defines the safety contract CTE7
  must use: encrypted/redacted outputs are the default, and plaintext export is
  impossible unless the caller explicitly opts in.
  """

  @modes [:encrypted, :redacted, :plaintext]

  @type plan :: %{
          mode: :encrypted | :redacted | :plaintext,
          plaintext?: boolean(),
          requires_restore_verification?: boolean(),
          warnings: [String.t()]
        }

  @spec plan(keyword()) :: {:ok, plan()} | {:error, term()}
  def plan(opts \\ []) do
    mode = Keyword.get(opts, :mode, :encrypted)

    cond do
      mode not in @modes ->
        {:error, {:invalid_backup_mode, mode}}

      mode == :plaintext and Keyword.get(opts, :allow_plaintext_export?, false) != true ->
        {:error, :plaintext_export_not_allowed}

      true ->
        {:ok,
         %{
           mode: mode,
           plaintext?: mode == :plaintext,
           requires_restore_verification?: true,
           warnings: warnings(mode)
         }}
    end
  end

  defp warnings(:encrypted), do: []
  defp warnings(:redacted), do: ["redacted export is not a restorable encrypted backup"]

  defp warnings(:plaintext) do
    [
      "plaintext export contains sensitive operational records and must be handled outside Twelvgaige"
    ]
  end
end
