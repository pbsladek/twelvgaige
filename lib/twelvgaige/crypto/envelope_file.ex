defmodule Twelvgaige.Crypto.EnvelopeFile do
  @moduledoc """
  JSON file codec for DEK envelopes.

  The wrapped DEK is encoded as base64 and never exposed through inspect output.
  File writes use private parent directories and best-effort private file modes.
  """

  alias Twelvgaige.Crypto.Envelope
  alias Twelvgaige.Security.FileMode

  @schema_version 1

  @spec read(Path.t()) :: {:ok, Envelope.t()} | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      decode(decoded)
    else
      {:error, :enoent} -> {:error, :envelope_not_found}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_envelope_file}
      {:error, _reason} = error -> error
    end
  end

  @spec write(Path.t(), Envelope.t()) :: :ok | {:error, term()}
  def write(path, %Envelope{} = envelope) when is_binary(path) do
    path = Path.expand(path)
    temp = "#{path}.tmp-#{System.unique_integer([:positive])}"
    contents = envelope |> encode() |> Jason.encode!()

    result =
      with :ok <- FileMode.ensure_private_parent_dir(path),
           :ok <- File.write(temp, contents, [:write]),
           :ok <- FileMode.chmod_if_supported(temp, 0o600),
           :ok <- File.rename(temp, path),
           :ok <- FileMode.chmod_if_supported(path, 0o600) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, _reason} = error ->
        _ignored = File.rm(temp)
        error
    end
  end

  @spec backup(Path.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def backup(source, destination) when is_binary(source) and is_binary(destination) do
    source = Path.expand(source)
    destination = Path.expand(destination)

    cond do
      not File.regular?(source) ->
        {:error, :envelope_not_found}

      File.exists?(destination) ->
        {:error, :envelope_backup_exists}

      true ->
        with :ok <- FileMode.ensure_private_parent_dir(destination),
             {:ok, bytes} <- File.copy(source, destination),
             :ok <- FileMode.chmod_if_supported(destination, 0o600) do
          {:ok, %{"source" => source, "destination" => destination, "bytes" => bytes}}
        end
    end
  end

  @spec encode(Envelope.t()) :: map()
  def encode(%Envelope{} = envelope) do
    %{
      "schema_version" => @schema_version,
      "envelope" => %{
        "schema_version" => envelope.schema_version,
        "key_id" => envelope.key_id,
        "key_backend" => Atom.to_string(envelope.key_backend),
        "algorithm" => envelope.algorithm,
        "wrapped_dek" => "base64:" <> Base.encode64(envelope.wrapped_dek),
        "metadata" => envelope.metadata
      }
    }
  end

  @spec decode(map()) :: {:ok, Envelope.t()} | {:error, term()}
  def decode(%{
        "schema_version" => @schema_version,
        "envelope" => %{
          "schema_version" => envelope_schema,
          "key_id" => key_id,
          "key_backend" => key_backend,
          "algorithm" => algorithm,
          "wrapped_dek" => "base64:" <> wrapped_dek,
          "metadata" => metadata
        }
      })
      when is_integer(envelope_schema) and is_binary(key_id) and is_binary(key_backend) and
             is_binary(algorithm) and is_map(metadata) do
    with {:ok, wrapped_dek} <- Base.decode64(wrapped_dek),
         {:ok, key_backend} <- key_backend_atom(key_backend) do
      {:ok,
       Envelope.new(
         schema_version: envelope_schema,
         key_id: key_id,
         key_backend: key_backend,
         algorithm: algorithm,
         wrapped_dek: wrapped_dek,
         metadata: metadata
       )}
    else
      :error -> {:error, :invalid_envelope_file}
      {:error, _reason} = error -> error
    end
  end

  def decode(_decoded), do: {:error, :invalid_envelope_file}

  defp key_backend_atom("env"), do: {:ok, :env}
  defp key_backend_atom("file"), do: {:ok, :file}
  defp key_backend_atom("test"), do: {:ok, :test}
  defp key_backend_atom("macos_keychain"), do: {:ok, :macos_keychain}
  defp key_backend_atom("linux_secret_service"), do: {:ok, :linux_secret_service}
  defp key_backend_atom(_backend), do: {:error, :unsupported_envelope_key_backend}
end
