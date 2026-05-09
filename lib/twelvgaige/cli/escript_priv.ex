defmodule Twelvgaige.CLI.EscriptPriv do
  @moduledoc false

  @priv_files [
    ~c"exqlite/ebin/exqlite.app",
    ~c"exqlite/priv/sqlite3_nif.so",
    ~c"exqlite/priv/sqlite3_nif.dll",
    ~c"exqlite/priv/sqlite3_nif.dylib"
  ]

  def prepare do
    script = :escript.script_name() |> List.to_string()

    if File.regular?(script) do
      extract(script)
    else
      :ok
    end
  end

  defp extract(script) do
    with {:ok, entries} <- :escript.extract(String.to_charlist(script), [:compile_source]),
         archive when is_binary(archive) <- Keyword.get(entries, :archive),
         {:ok, files} <- :zip.extract(archive, [:memory, {:file_list, @priv_files}]) do
      root = Path.join(System.tmp_dir!(), "twelvgaige-escript-#{:os.getpid()}")
      Enum.each(files, &write_file(root, &1))
      :code.add_patha(root |> Path.join("exqlite/ebin") |> String.to_charlist())
      :ok
    else
      {:error, {:badarg, _}} -> :ok
      {:error, :bad_central_directory} -> :ok
      {:error, _reason} = error -> error
      nil -> :ok
      _other -> :ok
    end
  end

  defp write_file(root, {path, contents}) do
    path = List.to_string(path)
    destination = Path.join(root, path)
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, contents)
  end
end
