defmodule Twelvgaige.Authoring.ShotLibrary do
  @moduledoc """
  Authoring-time shot template catalog.

  Templates are copied into workflow shells. Runtime execution never imports
  library entries dynamically.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Authoring.AtomicFile
  alias Twelvgaige.Shell.Document, as: ShellDocument
  alias Twelvgaige.Shell.Format.JSON, as: JSONFormat
  alias Twelvgaige.Shell.Format.TOML, as: TOMLFormat
  alias Twelvgaige.Shell.Format.YAML, as: YAMLFormat
  alias Twelvgaige.Shell.Loader
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Shell.Workflow.Shot

  @formats [
    {YAMLFormat, [".yaml", ".yml"]},
    {JSONFormat, [".json"]},
    {TOMLFormat, [".toml"]}
  ]

  @builtin_templates [
    %{
      "kind" => "shot_template",
      "namespace" => "builtin",
      "id" => "analysis.slug",
      "version" => "1.0.0",
      "description" => "Generic analysis shot for local workflows.",
      "shot" => %{
        "kind" => "slug",
        "agent" => "local_agent",
        "prompt" => "Analyze the current workflow context and return a concise finding."
      }
    },
    %{
      "kind" => "shot_template",
      "namespace" => "builtin",
      "id" => "safety.approval_gate",
      "version" => "1.0.0",
      "description" => "Human approval checkpoint before a risky follow-up shot.",
      "shot" => %{
        "kind" => "safety",
        "description" => "Approve or reject before continuing."
      }
    },
    %{
      "kind" => "shot_template",
      "namespace" => "builtin",
      "id" => "k8s.verify_recovery",
      "version" => "1.0.0",
      "description" => "Read-only Kubernetes recovery verification shot.",
      "shot" => %{
        "kind" => "slug",
        "agent" => "k8s_inspector",
        "tools" => ["kubectl_get", "kubectl_logs"],
        "prompt" => "Verify recovery by checking resource status and recent logs."
      }
    }
  ]

  @type template :: %{
          id: String.t(),
          namespace: String.t(),
          version: String.t(),
          description: String.t() | nil,
          source: :builtin | :local,
          path: Path.t() | nil,
          digest: String.t(),
          shot: map()
        }

  @spec list(keyword()) :: {:ok, [template()]} | {:error, Error.t()}
  def list(opts \\ []) do
    with {:ok, local} <- local_templates(opts) do
      {:ok, Enum.sort_by(builtin_templates() ++ local, &{&1.namespace, &1.id})}
    end
  end

  @spec verify(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def verify(opts \\ []) do
    lockfile = lockfile_path(opts)

    with {:ok, templates} <- local_templates(opts) do
      if Keyword.get(opts, :write_lock?, false) do
        write_lockfile(lockfile, templates)
      else
        verify_lockfile(lockfile, templates)
      end
    end
  end

  @spec update(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def update(opts \\ []) do
    lockfile = lockfile_path(opts)

    with {:ok, templates} <- local_templates(opts),
         {:ok, lock} <- load_lockfile(lockfile),
         {:ok, original} <- lockfile_contents(lockfile),
         {:ok, candidate} <- lockfile_candidate(lockfile, templates) do
      findings = lock_findings(lockfile, templates, lock)
      changed? = original != candidate

      if Keyword.get(opts, :write_lock?, false) do
        with :ok <- AtomicFile.write(lockfile, candidate) do
          {:ok, library_update_report(lockfile, templates, findings, changed?, "write_lock", nil)}
        end
      else
        diff = if changed?, do: unified_diff(lockfile, original, candidate), else: ""
        {:ok, library_update_report(lockfile, templates, findings, changed?, "dry_run", diff)}
      end
    end
  end

  @spec outdated(term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def outdated(path, opts \\ [])

  def outdated(path, opts) when is_binary(path) do
    with {:ok, templates} <- list(opts),
         {:ok, workflow_paths} <- workflow_paths(path),
         {:ok, scan} <- scan_template_usage(workflow_paths, templates) do
      status = if scan.findings == [] and scan.errors == [], do: "ok", else: "failed"

      {:ok,
       %{
         "kind" => "twelvgaige.library_outdated",
         "status" => status,
         "path" => Path.expand(path),
         "checked_workflows" => scan.checked_workflows,
         "checked_shots" => scan.checked_shots,
         "findings" => scan.findings,
         "errors" => scan.errors,
         "exit_code" => if(status == "ok", do: 0, else: 4)
       }}
    end
  end

  def outdated(_path, _opts) do
    {:error,
     Error.new(:input_error, :invalid_shell, "shot library outdated path must be a string")}
  end

  @spec fetch(String.t(), keyword()) :: {:ok, template()} | {:error, Error.t()}
  def fetch(id, opts \\ []) when is_binary(id) do
    with {:ok, templates} <- list(opts) do
      case Enum.find(templates, &(template_key(&1) == id or &1.id == id)) do
        nil ->
          {:error,
           Error.new(:input_error, :invalid_shell, "shot template not found",
             details: %{template: id, known_templates: Enum.map(templates, &template_key/1)}
           )}

        template ->
          {:ok, template}
      end
    end
  end

  @spec expand(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def expand(template_id, shot_id, opts \\ [])

  def expand(template_id, shot_id, opts)
      when is_binary(template_id) and is_binary(shot_id) do
    with {:ok, template} <- fetch(template_id, opts),
         shot = template.shot |> Map.put("id", shot_id) |> apply_overrides(opts),
         shot = put_template_metadata(shot, template),
         {:ok, %Shot{}} <- Shot.from_map(shot, ["shot"]) do
      {:ok, shot}
    end
  end

  def expand(_template_id, _shot_id, _opts) do
    {:error, Error.new(:input_error, :invalid_shell, "template id and shot id must be strings")}
  end

  @spec to_map(template()) :: map()
  def to_map(template) do
    %{
      "id" => template.id,
      "namespace" => template.namespace,
      "version" => template.version,
      "description" => template.description,
      "source" => Atom.to_string(template.source),
      "path" => template.path,
      "digest" => template.digest,
      "shot" => template.shot
    }
    |> compact()
  end

  defp builtin_templates do
    Enum.map(@builtin_templates, fn template ->
      normalize_template(template, :builtin, nil)
    end)
  end

  defp local_templates(opts) do
    opts
    |> library_dirs()
    |> Enum.reduce_while({:ok, []}, fn dir, {:ok, acc} ->
      case templates_in_dir(dir) do
        {:ok, templates} -> {:cont, {:ok, Enum.reverse(templates) ++ acc}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, templates} -> {:ok, Enum.reverse(templates)}
      {:error, _error} = error -> error
    end
  end

  defp library_dirs(opts) do
    explicit = opts |> Keyword.get(:library_paths, []) |> List.wrap()
    root = Keyword.get(opts, :root)
    root_dirs = if is_binary(root), do: [Path.join(root, "shots")], else: []

    (explicit ++ root_dirs)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp workflow_paths(path) do
    expanded = Path.expand(path)

    cond do
      File.dir?(expanded) ->
        paths =
          Loader.supported_extensions()
          |> Enum.map(&Path.join(expanded, "**/*#{&1}"))
          |> Enum.flat_map(&Path.wildcard/1)
          |> Enum.sort()
          |> Enum.uniq()

        {:ok, paths}

      File.exists?(expanded) ->
        {:ok, [expanded]}

      true ->
        {:error,
         Error.new(:input_error, :invalid_shell, "outdated scan path does not exist",
           details: %{path: expanded}
         )}
    end
  end

  defp scan_template_usage(paths, templates) do
    templates_by_key = Map.new(templates, &{template_key(&1), &1})

    scan =
      Enum.reduce(
        paths,
        %{checked_workflows: 0, checked_shots: 0, findings: [], errors: []},
        fn path, acc ->
          case Loader.load(path) do
            {:ok, %Workflow{} = workflow} ->
              scan_workflow(path, workflow, templates_by_key, acc)

            {:ok, _agent} ->
              acc

            {:error, %Error{} = error}
            when error.message == "shell kind must be workflow or agent" ->
              acc

            {:error, %Error{} = error} ->
              update_in(acc.errors, &[%{"path" => path, "error" => Error.to_map(error)} | &1])
          end
        end
      )

    {:ok,
     %{
       scan
       | findings: Enum.reverse(scan.findings),
         errors: Enum.reverse(scan.errors)
     }}
  end

  defp scan_workflow(path, %Workflow{} = workflow, templates_by_key, acc) do
    workflow.shots
    |> Enum.reduce(
      %{acc | checked_workflows: acc.checked_workflows + 1},
      fn shot, acc ->
        sources = template_sources(shot)
        acc = %{acc | checked_shots: acc.checked_shots + length(sources)}

        Enum.reduce(sources, acc, fn source, acc ->
          findings = template_source_findings(path, workflow, shot, source, templates_by_key)
          update_in(acc.findings, &(Enum.reverse(findings) ++ &1))
        end)
      end
    )
  end

  defp template_sources(%Shot{} = shot) do
    case get_in(shot.metadata.generated_by, ["source"]) do
      %{"kind" => "template"} = source -> [source]
      _other -> []
    end
  end

  defp template_source_findings(path, workflow, shot, source, templates_by_key) do
    key = source_key(source)

    cond do
      is_nil(key) ->
        [template_usage_finding("template_source_invalid", path, workflow, shot, source, nil)]

      is_nil(Map.get(source, "digest")) ->
        [template_usage_finding("source_digest_missing", path, workflow, shot, source, key)]

      template = Map.get(templates_by_key, key) ->
        digest_or_version_findings(path, workflow, shot, source, key, template)

      true ->
        [template_usage_finding("template_missing", path, workflow, shot, source, key)]
    end
  end

  defp digest_or_version_findings(path, workflow, shot, source, key, template) do
    []
    |> maybe_digest_mismatch(path, workflow, shot, source, key, template)
    |> maybe_version_mismatch(path, workflow, shot, source, key, template)
  end

  defp maybe_digest_mismatch(findings, path, workflow, shot, source, key, template) do
    if Map.get(source, "digest") == template.digest do
      findings
    else
      [
        template_usage_finding("digest_mismatch", path, workflow, shot, source, key, %{
          "current_digest" => template.digest
        })
        | findings
      ]
    end
  end

  defp maybe_version_mismatch(findings, path, workflow, shot, source, key, template) do
    source_version = Map.get(source, "version")

    if is_nil(source_version) or source_version == template.version do
      findings
    else
      [
        template_usage_finding("version_mismatch", path, workflow, shot, source, key, %{
          "current_version" => template.version
        })
        | findings
      ]
    end
  end

  defp template_usage_finding(status, path, workflow, shot, source, template, extra \\ %{}) do
    %{
      "status" => status,
      "message" => template_usage_message(status),
      "path" => path,
      "workflow" => workflow.id,
      "shot" => shot.id,
      "template" => template,
      "source_digest" => Map.get(source, "digest"),
      "source_version" => Map.get(source, "version")
    }
    |> Map.merge(extra)
    |> compact()
  end

  defp template_usage_message("digest_mismatch"), do: "copied shot template digest is outdated"
  defp template_usage_message("version_mismatch"), do: "copied shot template version is outdated"
  defp template_usage_message("template_missing"), do: "copied shot references a missing template"

  defp template_usage_message("source_digest_missing"),
    do: "copied shot template source is missing a digest"

  defp template_usage_message("template_source_invalid"),
    do: "copied shot template source is invalid"

  defp source_key(%{"namespace" => namespace, "id" => id})
       when is_binary(namespace) and is_binary(id) do
    "#{namespace}/#{id}"
  end

  defp source_key(%{"id" => id}) when is_binary(id) do
    if String.contains?(id, "/"), do: id, else: nil
  end

  defp source_key(_source), do: nil

  defp templates_in_dir(dir) do
    if File.dir?(dir) do
      dir
      |> shell_paths_in_dir()
      |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
        case load_template(path) do
          {:ok, template} -> {:cont, {:ok, [template | acc]}}
          {:error, _error} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, templates} -> {:ok, Enum.reverse(templates)}
        {:error, _error} = error -> error
      end
    else
      {:ok, []}
    end
  end

  defp lockfile_path(opts) do
    cond do
      path = Keyword.get(opts, :lockfile) ->
        Path.expand(path)

      root = Keyword.get(opts, :root) ->
        root |> Path.join("twelvgaige-library.lock") |> Path.expand()

      true ->
        Path.expand("twelvgaige-library.lock")
    end
  end

  defp shell_paths_in_dir(dir) do
    @formats
    |> Enum.flat_map(fn {_format, extensions} -> extensions end)
    |> Enum.flat_map(&Path.wildcard(Path.join(dir, "**/*#{&1}")))
    |> Enum.sort()
  end

  defp load_template(path) do
    with {:ok, format} <- format_for_path(path),
         {:ok, contents} <- File.read(path),
         {:ok, map} <- format.parse(contents, path) do
      {:ok, normalize_template(map, :local, path)}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:input_error, :invalid_shell, "unable to load shot template",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp write_lockfile(lockfile, templates) do
    with {:ok, contents} <- lockfile_candidate(lockfile, templates),
         :ok <- AtomicFile.write(lockfile, contents) do
      {:ok,
       %{
         "kind" => "twelvgaige.library_verify",
         "status" => "ok",
         "mode" => "write_lock",
         "lockfile" => lockfile,
         "checked" => length(templates),
         "findings" => [],
         "exit_code" => 0
       }}
    end
  end

  defp lockfile_candidate(lockfile, templates) do
    with {:ok, preserved_entries} <- preserved_lock_entries(lockfile, "shot_template") do
      lockfile
      |> lock_document(templates, preserved_entries)
      |> ShellDocument.encode(:yaml)
    end
  end

  defp lockfile_contents(lockfile) do
    case File.read(lockfile) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, :enoent} ->
        {:ok, ""}

      {:error, reason} ->
        {:error,
         Error.new(:input_error, :invalid_shell, "unable to read library lockfile",
           details: %{lockfile: lockfile, reason: inspect(reason)}
         )}
    end
  end

  defp library_update_report(lockfile, templates, findings, changed?, mode, diff) do
    %{
      "kind" => "twelvgaige.library_update",
      "status" => "ok",
      "mode" => mode,
      "lockfile" => lockfile,
      "checked" => length(templates),
      "changed" => changed?,
      "findings" => findings,
      "diff" => diff,
      "exit_code" => 0
    }
    |> compact()
  end

  defp verify_lockfile(lockfile, templates) do
    with {:ok, lock} <- load_lockfile(lockfile) do
      findings = lock_findings(lockfile, templates, lock)
      status = if findings == [], do: "ok", else: "failed"

      {:ok,
       %{
         "kind" => "twelvgaige.library_verify",
         "status" => status,
         "mode" => "verify",
         "lockfile" => lockfile,
         "checked" => length(templates),
         "findings" => findings,
         "exit_code" => if(status == "ok", do: 0, else: 4)
       }}
    end
  end

  defp load_lockfile(lockfile) do
    with {:ok, contents} <- File.read(lockfile),
         {:ok, document} <- YAMLFormat.parse(contents, lockfile),
         :ok <- validate_lockfile(document, lockfile) do
      {:ok, document}
    else
      {:error, :enoent} ->
        {:ok,
         %{
           "kind" => "library_lock",
           "version" => 1,
           "entries" => [
             %{
               "status" => "missing_lockfile",
               "source" => lockfile
             }
           ]
         }}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:input_error, :invalid_shell, "unable to read library lockfile",
           details: %{lockfile: lockfile, reason: inspect(reason)}
         )}
    end
  end

  defp validate_lockfile(%{"kind" => "library_lock", "entries" => entries}, _lockfile)
       when is_list(entries),
       do: :ok

  defp validate_lockfile(_document, lockfile) do
    {:error,
     Error.new(:input_error, :invalid_shell, "library lockfile must be kind: library_lock",
       details: %{lockfile: lockfile}
     )}
  end

  defp lock_document(lockfile, templates, preserved_entries) do
    %{
      "kind" => "library_lock",
      "version" => 1,
      "entries" =>
        (preserved_entries ++ Enum.map(templates, &lock_entry(lockfile, &1)))
        |> Enum.sort_by(&{&1["kind"], Map.get(&1, "namespace", ""), Map.get(&1, "id", "")})
    }
  end

  defp preserved_lock_entries(lockfile, replaced_kind) do
    case load_lockfile(lockfile) do
      {:ok, %{"entries" => [%{"status" => "missing_lockfile"}]}} ->
        {:ok, []}

      {:ok, %{"entries" => entries}} ->
        {:ok, Enum.reject(entries, &(Map.get(&1, "kind") == replaced_kind))}

      {:error, _error} = error ->
        error
    end
  end

  defp lock_entry(lockfile, template) do
    %{
      "kind" => "shot_template",
      "namespace" => template.namespace,
      "id" => template.id,
      "version" => template.version,
      "source" => relative_source(lockfile, template.path),
      "digest" => template.digest
    }
  end

  defp relative_source(_lockfile, nil), do: nil

  defp relative_source(lockfile, path) do
    Path.relative_to(path, Path.dirname(lockfile))
  end

  defp lock_findings(lockfile, _templates, %{"entries" => [%{"status" => "missing_lockfile"}]}) do
    [
      %{
        "status" => "missing_lockfile",
        "message" => "library lockfile does not exist",
        "lockfile" => lockfile
      }
    ]
  end

  defp lock_findings(lockfile, templates, %{"entries" => entries}) do
    template_entries = Enum.filter(entries, &(Map.get(&1, "kind") == "shot_template"))
    entries_by_key = Map.new(template_entries, &{entry_key(&1), &1})
    templates_by_key = Map.new(templates, &{template_key(&1), &1})

    missing_entries =
      templates
      |> Enum.flat_map(fn template ->
        case Map.fetch(entries_by_key, template_key(template)) do
          {:ok, entry} -> digest_finding(lockfile, template, entry)
          :error -> [missing_lock_entry(template)]
        end
      end)

    stale_entries =
      template_entries
      |> Enum.flat_map(fn entry ->
        case Map.fetch(templates_by_key, entry_key(entry)) do
          {:ok, _template} -> []
          :error -> [missing_template(lockfile, entry)]
        end
      end)

    missing_entries ++ stale_entries
  end

  defp digest_finding(_lockfile, template, %{"digest" => digest}) when digest == template.digest,
    do: []

  defp digest_finding(lockfile, template, entry) do
    [
      %{
        "status" => "digest_mismatch",
        "message" => "shot template digest does not match library lock",
        "template" => template_key(template),
        "source" => relative_source(lockfile, template.path),
        "expected_digest" => Map.get(entry, "digest"),
        "actual_digest" => template.digest
      }
    ]
  end

  defp missing_lock_entry(template) do
    %{
      "status" => "missing_lock_entry",
      "message" => "shot template is not present in the library lock",
      "template" => template_key(template),
      "digest" => template.digest,
      "source" => template.path
    }
  end

  defp missing_template(lockfile, entry) do
    %{
      "status" => "missing_template",
      "message" => "library lock references a missing shot template",
      "template" => entry_key(entry),
      "source" => Map.get(entry, "source"),
      "expected_path" => lockfile |> Path.dirname() |> Path.join(Map.get(entry, "source", ""))
    }
  end

  defp unified_diff(path, original, candidate) do
    original_lines = String.split(original, "\n", trim: false)
    candidate_lines = String.split(candidate, "\n", trim: false)
    max = max(length(original_lines), length(candidate_lines))

    body =
      0..(max - 1)
      |> Enum.flat_map(fn index ->
        old = Enum.at(original_lines, index)
        new = Enum.at(candidate_lines, index)

        cond do
          old == new and not is_nil(old) -> [" #{old}"]
          is_nil(old) -> ["+#{new}"]
          is_nil(new) -> ["-#{old}"]
          true -> ["-#{old}", "+#{new}"]
        end
      end)
      |> Enum.reject(&(&1 in [" ", "+", "-"]))
      |> Enum.join("\n")

    """
    --- #{path}
    +++ #{path}
    @@
    #{body}
    """
  end

  defp entry_key(entry), do: "#{Map.get(entry, "namespace", "local")}/#{Map.get(entry, "id")}"

  defp normalize_template(map, source, path) do
    %{
      id: Map.fetch!(map, "id"),
      namespace: Map.get(map, "namespace", namespace_for(source)),
      version: Map.get(map, "version", "1.0.0"),
      description: Map.get(map, "description"),
      source: source,
      path: path,
      digest: digest(map),
      shot: Map.fetch!(map, "shot")
    }
  end

  defp namespace_for(:builtin), do: "builtin"
  defp namespace_for(:local), do: "local"

  defp format_for_path(path) do
    extension = path |> Path.extname() |> String.downcase()

    case Enum.find(@formats, fn {_format, extensions} -> extension in extensions end) do
      {format, _extensions} ->
        {:ok, format}

      nil ->
        {:error,
         Error.new(:input_error, :invalid_shell, "unsupported shot template extension",
           details: %{path: path, extension: extension}
         )}
    end
  end

  defp apply_overrides(shot, opts) do
    shot
    |> maybe_put("agent", Keyword.get(opts, :agent))
    |> maybe_put("prompt", Keyword.get(opts, :prompt))
    |> maybe_put("description", Keyword.get(opts, :description))
    |> put_non_empty("depends_on", Keyword.get(opts, :depends_on, []))
    |> append_tools(Keyword.get(opts, :tools, []))
  end

  defp put_template_metadata(shot, template) do
    source =
      %{
        "kind" => "template",
        "namespace" => template.namespace,
        "id" => template.id,
        "version" => template.version,
        "digest" => template.digest,
        "path" => template.path
      }
      |> compact()

    metadata =
      shot
      |> Map.get("metadata", %{})
      |> Map.put("generated_by", %{
        "tool" => "twelvgaige",
        "command" => "shot add --template #{template_key(template)}",
        "version" => Twelvgaige.version(),
        "source" => source
      })

    Map.put(shot, "metadata", metadata)
  end

  defp append_tools(shot, []), do: shot

  defp append_tools(shot, tools) do
    existing = Map.get(shot, "tools", [])
    Map.put(shot, "tools", Enum.uniq(existing ++ tools))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_non_empty(map, _key, []), do: map
  defp put_non_empty(map, key, value), do: Map.put(map, key, value)

  defp template_key(template), do: "#{template.namespace}/#{template.id}"

  defp digest(map) do
    encoded = canonical_json(map)
    "sha256:" <> (:crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower))
  end

  defp canonical_json(value) when is_map(value) do
    pairs =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} ->
        Jason.encode!(to_string(key)) <> ":" <> canonical_json(value)
      end)

    "{" <> Enum.join(pairs, ",") <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> (value |> Enum.map(&canonical_json/1) |> Enum.join(",")) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp compact(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      value = compact(value)
      if value in [nil, %{}, []], do: acc, else: Map.put(acc, key, value)
    end)
  end

  defp compact(list) when is_list(list), do: Enum.map(list, &compact/1)
  defp compact(value), do: value
end
