defmodule Twelvgaige.Developer.Config do
  @moduledoc "Project and user developer profiles for repeatable local session defaults."

  alias Twelvgaige.CLI.SessionTaskFile
  alias Twelvgaige.Shell.Format.YAML

  @top_fields ~w(version default_profile profiles)
  @profile_fields ~w(
    runtime repository repo base_ref auth_profile sandbox network allow_unrestricted_network
    allowed_paths source include_untracked include_ignored write timeout timeout_ms budget
  )

  @spec resolve_profile(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_profile(requested \\ nil, opts \\ []) do
    project_root = project_root(opts)
    user_path = Keyword.get(opts, :user_config_path, user_config_path(opts))
    project_path = Keyword.get(opts, :project_config_path, project_config_path(project_root))

    with {:ok, user} <- load_config(user_path),
         {:ok, project} <- load_config(project_path),
         name <- requested || project.default_profile || user.default_profile,
         {:ok, values, sources, provenance} <- resolve(name, user, project) do
      {:ok,
       %{
         name: name,
         values: values,
         project_root: project_root,
         user_config_path: user_path,
         project_config_path: project_path,
         sources: sources,
         provenance: provenance
       }}
    end
  end

  @doc "Returns configured developer-profile names without resolving credentials or runtime state."
  def profile_names(opts \\ []) do
    project_root = project_root(opts)
    user_path = Keyword.get(opts, :user_config_path, user_config_path(opts))
    project_path = Keyword.get(opts, :project_config_path, project_config_path(project_root))

    with {:ok, user} <- load_config(user_path),
         {:ok, project} <- load_config(project_path) do
      {:ok, (Map.keys(user.profiles) ++ Map.keys(project.profiles)) |> Enum.uniq() |> Enum.sort()}
    end
  end

  def project_root(opts \\ []) do
    case Keyword.get(opts, :project_root) do
      nil ->
        start = Path.expand(Keyword.get(opts, :cwd, File.cwd!()))
        discover_project_root(start, start)

      root ->
        Path.expand(root)
    end
  end

  def user_config_path(opts \\ []) do
    base =
      Keyword.get(opts, :xdg_config_home) || System.get_env("XDG_CONFIG_HOME") ||
        Path.join(System.user_home!(), ".config")

    Path.join([base, "twelvgaige", "config.yaml"])
  end

  def project_config_path(root), do: Path.join([root, ".twelvgaige", "config.yaml"])

  defp load_config(path) do
    case File.read(path) do
      {:ok, contents} ->
        parse_config(contents, path)

      {:error, :enoent} ->
        {:ok, %{default_profile: nil, profiles: %{}, present?: false, path: path}}

      {:error, reason} ->
        {:error, {:developer_config_unreadable, path, reason}}
    end
  end

  defp parse_config(contents, path) do
    with {:ok, document} <- YAML.parse(contents, path),
         :ok <- known_keys(document, @top_fields, :developer_config_unknown_fields),
         :ok <- version(document),
         {:ok, profiles} <- profiles(Map.get(document, "profiles", %{}), path),
         :ok <- default_profile(Map.get(document, "default_profile"), profiles) do
      {:ok,
       %{
         default_profile: Map.get(document, "default_profile"),
         profiles: profiles,
         present?: true,
         path: path
       }}
    else
      {:error, %Twelvgaige.Error{} = error} ->
        {:error, {:developer_config_yaml_invalid, path, error.message}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp profiles(profiles, path) when is_map(profiles) do
    Enum.reduce_while(profiles, {:ok, %{}}, fn {name, profile}, {:ok, acc} ->
      with true <- present?(name) or {:error, :developer_profile_name_invalid},
           true <- is_map(profile) or {:error, {:developer_profile_invalid, name}},
           :ok <- known_keys(profile, @profile_fields, {:developer_profile_unknown_fields, name}),
           {:ok, values} <-
             SessionTaskFile.normalize_yaml(Map.put(profile, "version", 1), path) do
        {:cont, {:ok, Map.put(acc, name, values)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp profiles(_profiles, _path), do: {:error, :developer_profiles_invalid}

  defp resolve(nil, user, project) do
    sources = Enum.filter([user, project], & &1.present?) |> Enum.map(& &1.path)
    {:ok, %{}, sources, %{}}
  end

  defp resolve(name, user, project) when is_binary(name) do
    user_values = Map.get(user.profiles, name, %{})
    project_values = Map.get(project.profiles, name, %{})

    if map_size(user_values) == 0 and map_size(project_values) == 0 do
      {:error, {:developer_profile_not_found, name}}
    else
      sources =
        [{user.path, user_values}, {project.path, project_values}]
        |> Enum.reject(fn {_path, values} -> map_size(values) == 0 end)
        |> Enum.map(&elem(&1, 0))

      provenance =
        user_values
        |> Map.keys()
        |> Map.new(&{&1, :user_profile})
        |> Map.merge(Map.new(Map.keys(project_values), &{&1, :repository_profile}))

      {:ok, Map.merge(user_values, project_values), sources, provenance}
    end
  end

  defp version(document) do
    case Map.get(document, "version", 1) do
      1 -> :ok
      value -> {:error, {:developer_config_version_unsupported, value}}
    end
  end

  defp default_profile(nil, _profiles), do: :ok

  defp default_profile(name, profiles) when is_binary(name) do
    if Map.has_key?(profiles, name),
      do: :ok,
      else: {:error, {:developer_default_profile_not_found, name}}
  end

  defp default_profile(_name, _profiles), do: {:error, :developer_default_profile_invalid}

  defp known_keys(map, allowed, error) when is_map(map) do
    unknown = map |> Map.keys() |> Enum.reject(&Enum.member?(allowed, &1)) |> Enum.sort()
    if unknown == [], do: :ok, else: {:error, {error, unknown}}
  end

  defp discover_project_root(cwd, fallback) do
    cwd = Path.expand(cwd)

    cond do
      File.regular?(project_config_path(cwd)) -> cwd
      File.dir?(Path.join(cwd, ".git")) -> cwd
      Path.dirname(cwd) == cwd -> fallback
      true -> discover_project_root(Path.dirname(cwd), fallback)
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
