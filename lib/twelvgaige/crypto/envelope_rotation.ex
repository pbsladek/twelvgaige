defmodule Twelvgaige.Crypto.EnvelopeRotation do
  @moduledoc """
  Operator-facing DEK envelope rotation helpers.

  Rewrap rotation changes only the encrypted DEK envelope. It does not rekey a
  SQLCipher database or rewrite database pages.
  """

  alias Twelvgaige.Crypto.EnvelopeCipher
  alias Twelvgaige.Crypto.EnvelopeFile
  alias Twelvgaige.Crypto.KeyManager
  alias Twelvgaige.Crypto.KeyManager.EnvBackend

  @spec rewrap_file(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rewrap_file(path, opts) when is_binary(path) and is_list(opts) do
    path = Path.expand(path)
    backup_path = Keyword.get(opts, :backup)

    with {:ok, backup_path} <- require_backup_path(backup_path),
         {:ok, old_env} <- require_env(opts, :old_key_env),
         {:ok, new_env} <- require_env(opts, :new_key_env),
         {:ok, old_envelope} <- EnvelopeFile.read(path),
         {:ok, _backup} <- EnvelopeFile.backup(path, backup_path),
         {:ok, old_key} <- fetch_env_key(old_envelope.key_id, old_env),
         {:ok, new_key} <- fetch_env_key(old_envelope.key_id, new_env),
         {:ok, new_envelope} <- EnvelopeCipher.rewrap_dek(old_envelope, old_key, new_key),
         :ok <- EnvelopeFile.write(path, new_envelope) do
      {:ok,
       %{
         "status" => "ok",
         "mode" => "rewrap",
         "path" => path,
         "backup" => backup_path,
         "key_id" => new_envelope.key_id,
         "key_backend" => Atom.to_string(new_envelope.key_backend),
         "previous_key_id" => new_envelope.metadata["previous_key_id"],
         "previous_key_backend" => new_envelope.metadata["previous_key_backend"],
         "rotation" => new_envelope.metadata["rotation"],
         "rotated_at" => new_envelope.metadata["rotated_at"],
         "database_rekeyed" => false,
         "warnings" => [
           "rewrap rotates only the DEK envelope; it does not re-encrypt SQLCipher database pages"
         ]
       }}
    end
  end

  defp require_backup_path(path) when is_binary(path) and path != "", do: {:ok, Path.expand(path)}
  defp require_backup_path(_path), do: {:error, :envelope_backup_required}

  defp require_env(opts, key) do
    case Keyword.get(opts, key) do
      env when is_binary(env) and env != "" -> {:ok, env}
      _missing -> {:error, :"#{key}_required"}
    end
  end

  defp fetch_env_key(key_id, env) do
    KeyManager.fetch_key(EnvBackend, key_id,
      env: env,
      allow_insecure_key_backend?: true
    )
  end
end
