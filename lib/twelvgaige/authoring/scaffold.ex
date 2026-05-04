defmodule Twelvgaige.Authoring.Scaffold do
  @moduledoc """
  Deterministic workflow scaffolds and scaffold libraries.

  Scaffolds are authoring inputs only. Expansion returns ordinary workflow and
  agent shell maps that must validate through the normal shell loader.
  """

  alias Twelvgaige.Authoring.AtomicFile
  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Agent
  alias Twelvgaige.Shell.Document, as: ShellDocument
  alias Twelvgaige.Shell.Format.JSON, as: JSONFormat
  alias Twelvgaige.Shell.Format.TOML, as: TOMLFormat
  alias Twelvgaige.Shell.Format.YAML, as: YAMLFormat
  alias Twelvgaige.Shell.Loader
  alias Twelvgaige.Shell.Workflow

  @formats [
    {YAMLFormat, [".yaml", ".yml"]},
    {JSONFormat, [".json"]},
    {TOMLFormat, [".toml"]}
  ]

  @scaffolds ~w(single-shot inspect-analyze-gate-fix-verify)
  @scaffold_version "1.0.0"

  @type expansion :: %{
          scaffold: String.t(),
          workflow: map(),
          agents: [map()]
        }

  @type entry :: %{
          id: String.t(),
          namespace: String.t(),
          version: String.t(),
          description: String.t() | nil,
          source: :builtin | :local,
          path: Path.t() | nil,
          digest: String.t(),
          workflow: map(),
          agents: [map()]
        }

  @spec names() :: [String.t()]
  def names, do: @scaffolds

  @spec list(keyword()) :: {:ok, [entry()]} | {:error, Error.t()}
  def list(opts \\ []) do
    with {:ok, local} <- local_scaffolds(opts) do
      {:ok, Enum.sort_by(builtin_entries() ++ local, &{&1.namespace, &1.id})}
    end
  end

  @spec fetch(String.t(), keyword()) :: {:ok, entry()} | {:error, Error.t()}
  def fetch(id, opts \\ []) when is_binary(id) do
    with {:ok, scaffolds} <- list(opts) do
      case Enum.find(scaffolds, &(entry_key(&1) == id or &1.id == id)) do
        nil ->
          {:error,
           Error.new(:input_error, :invalid_shell, "scaffold not found",
             details: %{scaffold: id, known_scaffolds: known_scaffold_names(scaffolds)}
           )}

        scaffold ->
          {:ok, scaffold}
      end
    end
  end

  @spec expand(String.t(), String.t(), keyword()) :: {:ok, expansion()} | {:error, Error.t()}
  def expand(scaffold, workflow_id, opts \\ [])
      when is_binary(scaffold) and is_binary(workflow_id) do
    with :ok <- validate_workflow_id(workflow_id),
         {:ok, entry} <- fetch(scaffold, opts),
         {:ok, workflow} <- expand_workflow(entry, workflow_id),
         workflow <- put_generated_metadata(workflow, entry),
         {:ok, workflow} <- validate_workflow(workflow),
         agents <- entry.agents ++ maybe_mock_agents(workflow, opts),
         :ok <- validate_agents(agents) do
      {:ok, %{scaffold: scaffold, workflow: workflow, agents: agents}}
    end
  end

  @spec verify(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def verify(opts \\ []) do
    lockfile = lockfile_path(opts)

    with {:ok, scaffolds} <- local_scaffolds(opts) do
      if Keyword.get(opts, :write_lock?, false) do
        write_lockfile(lockfile, scaffolds)
      else
        verify_lockfile(lockfile, scaffolds)
      end
    end
  end

  @spec update(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def update(opts \\ []) do
    lockfile = lockfile_path(opts)

    with {:ok, scaffolds} <- local_scaffolds(opts),
         {:ok, lock} <- load_lockfile(lockfile),
         {:ok, original} <- lockfile_contents(lockfile),
         {:ok, candidate} <- lockfile_candidate(lockfile, scaffolds) do
      findings = lock_findings(lockfile, scaffolds, lock)
      changed? = original != candidate

      if Keyword.get(opts, :write_lock?, false) do
        with :ok <- AtomicFile.write(lockfile, candidate) do
          {:ok, library_update_report(lockfile, scaffolds, findings, changed?, "write_lock", nil)}
        end
      else
        diff = if changed?, do: unified_diff(lockfile, original, candidate), else: ""
        {:ok, library_update_report(lockfile, scaffolds, findings, changed?, "dry_run", diff)}
      end
    end
  end

  @spec outdated(term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def outdated(path, opts \\ [])

  def outdated(path, opts) when is_binary(path) do
    with {:ok, scaffolds} <- list(opts),
         {:ok, workflow_paths} <- workflow_paths(path),
         {:ok, scan} <- scan_scaffold_usage(workflow_paths, scaffolds) do
      status = if scan.findings == [] and scan.errors == [], do: "ok", else: "failed"

      {:ok,
       %{
         "kind" => "twelvgaige.scaffold_outdated",
         "status" => status,
         "path" => Path.expand(path),
         "checked_workflows" => scan.checked_workflows,
         "findings" => scan.findings,
         "errors" => scan.errors,
         "exit_code" => if(status == "ok", do: 0, else: 4)
       }}
    end
  end

  def outdated(_path, _opts) do
    {:error, Error.new(:input_error, :invalid_shell, "scaffold outdated path must be a string")}
  end

  @spec to_map(entry()) :: map()
  def to_map(entry) do
    %{
      "id" => entry.id,
      "namespace" => entry.namespace,
      "version" => entry.version,
      "description" => entry.description,
      "source" => Atom.to_string(entry.source),
      "path" => entry.path,
      "digest" => entry.digest,
      "workflow" => entry.workflow,
      "agents" => entry.agents
    }
    |> compact()
  end

  defp builtin_entries do
    Enum.map(@scaffolds, fn scaffold ->
      {:ok, workflow} = builtin_workflow(scaffold, "__workflow_id__")

      %{
        id: scaffold,
        namespace: "builtin",
        version: @scaffold_version,
        description: builtin_description(scaffold),
        source: :builtin,
        path: nil,
        digest:
          digest(%{
            "kind" => "scaffold",
            "namespace" => "builtin",
            "id" => scaffold,
            "version" => @scaffold_version,
            "workflow" => workflow,
            "agents" => []
          }),
        workflow: workflow,
        agents: []
      }
    end)
  end

  defp builtin_description("single-shot"), do: "Minimal one-shot mocked workflow."

  defp builtin_description("inspect-analyze-gate-fix-verify"),
    do: "Inspect, analyze, approve, remediate, and verify workflow skeleton."

  defp expand_workflow(%{source: :builtin, id: scaffold}, workflow_id),
    do: builtin_workflow(scaffold, workflow_id)

  defp expand_workflow(entry, workflow_id) do
    workflow =
      entry.workflow
      |> Map.put("kind", "workflow")
      |> Map.put("id", workflow_id)
      |> Map.put_new("name", titleize(workflow_id))
      |> Map.put_new("version", entry.version)

    {:ok, workflow}
  end

  defp builtin_workflow("single-shot", workflow_id) do
    agent_id = "#{workflow_id}_agent"

    {:ok,
     %{
       "kind" => "workflow",
       "id" => workflow_id,
       "name" => titleize(workflow_id),
       "version" => @scaffold_version,
       "shots" => [
         %{
           "id" => "analyze",
           "kind" => "slug",
           "agent" => agent_id,
           "timeout" => "2m",
           "prompt" =>
             prompt_with_example("Analyze the input and return a concise summary.", %{
               "summary" => "mock summary"
             }),
           "output_schema" => summary_schema()
         }
       ]
     }}
  end

  defp builtin_workflow("inspect-analyze-gate-fix-verify", workflow_id) do
    inspector = "#{workflow_id}_inspector"
    analyst = "#{workflow_id}_analyst"
    operator = "#{workflow_id}_operator"

    {:ok,
     %{
       "kind" => "workflow",
       "id" => workflow_id,
       "name" => titleize(workflow_id),
       "version" => @scaffold_version,
       "shots" => [
         %{
           "id" => "inspect",
           "kind" => "slug",
           "agent" => inspector,
           "timeout" => "2m",
           "prompt" =>
             prompt_with_example("Inspect current state and summarize relevant evidence.", %{
               "summary" => "mock inspection summary"
             }),
           "tools" => ["kubectl_get"],
           "output_schema" => summary_schema()
         },
         %{
           "id" => "analyze",
           "kind" => "slug",
           "agent" => analyst,
           "depends_on" => ["inspect"],
           "timeout" => "3m",
           "prompt" =>
             prompt_with_example("Analyze inspection evidence and recommend next action.", %{
               "summary" => "mock analysis summary",
               "requires_action" => true
             }),
           "output_schema" => %{
             "type" => "object",
             "required" => ["summary", "requires_action"],
             "properties" => %{
               "summary" => %{"type" => "string"},
               "requires_action" => %{"type" => "boolean"}
             }
           }
         },
         %{
           "id" => "approval",
           "kind" => "safety",
           "depends_on" => ["analyze"],
           "description" => "Approve the proposed remediation before any write-capable action."
         },
         %{
           "id" => "remediate",
           "kind" => "slug",
           "agent" => operator,
           "depends_on" => ["approval"],
           "timeout" => "5m",
           "tools" => ["kubectl_apply"],
           "choke" => %{"tool_safety" => "idempotent_write"},
           "prompt" =>
             prompt_with_example("Apply the approved remediation using only allowed tools.", %{
               "summary" => "mock remediation summary",
               "changed" => false
             }),
           "output_schema" => %{
             "type" => "object",
             "required" => ["summary", "changed"],
             "properties" => %{
               "summary" => %{"type" => "string"},
               "changed" => %{"type" => "boolean"}
             }
           }
         },
         %{
           "id" => "verify",
           "kind" => "slug",
           "agent" => inspector,
           "depends_on" => ["remediate"],
           "timeout" => "2m",
           "tools" => ["kubectl_get"],
           "prompt" =>
             prompt_with_example("Verify the system state after remediation.", %{
               "summary" => "mock verification summary"
             }),
           "output_schema" => summary_schema()
         }
       ]
     }}
  end

  defp local_scaffolds(opts) do
    opts
    |> scaffold_dirs()
    |> Enum.reduce_while({:ok, []}, fn dir, {:ok, acc} ->
      case scaffolds_in_dir(dir) do
        {:ok, scaffolds} -> {:cont, {:ok, acc ++ scaffolds}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp scaffold_dirs(opts) do
    explicit = opts |> Keyword.get(:scaffold_paths, []) |> List.wrap()
    root = Keyword.get(opts, :root)
    root_dirs = if is_binary(root), do: [Path.join(root, "scaffolds")], else: []

    (explicit ++ root_dirs)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp scaffolds_in_dir(dir) do
    if File.dir?(dir) do
      dir
      |> shell_paths_in_dir()
      |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
        case load_scaffold(path) do
          {:ok, scaffold} -> {:cont, {:ok, [scaffold | acc]}}
          {:error, _error} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, scaffolds} -> {:ok, Enum.reverse(scaffolds)}
        {:error, _error} = error -> error
      end
    else
      {:ok, []}
    end
  end

  defp load_scaffold(path) do
    with {:ok, format} <- format_for_path(path),
         {:ok, contents} <- File.read(path),
         {:ok, map} <- format.parse(contents, path),
         {:ok, entry} <- normalize_entry(map, :local, path),
         :ok <- validate_entry(entry, path) do
      {:ok, entry}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:input_error, :invalid_shell, "unable to load scaffold",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp normalize_entry(%{"kind" => "scaffold"} = map, source, path) do
    with {:ok, id} <- required_string(map, "id", path),
         {:ok, workflow} <- required_map(map, "workflow", path),
         {:ok, agents} <- optional_list(map, "agents", path) do
      {:ok,
       %{
         id: id,
         namespace: Map.get(map, "namespace", namespace_for(source)),
         version: Map.get(map, "version", @scaffold_version),
         description: Map.get(map, "description"),
         source: source,
         path: path,
         digest: digest(map),
         workflow: workflow,
         agents: agents
       }}
    end
  end

  defp normalize_entry(map, _source, path) do
    {:error,
     Error.new(:input_error, :invalid_shell, "scaffold document must be kind: scaffold",
       details: %{path: path, kind: Map.get(map, "kind")}
     )}
  end

  defp validate_entry(entry, path) do
    with {:ok, workflow} <- expand_workflow(entry, "__scaffold_validate__"),
         {:ok, _workflow} <- Workflow.from_map(workflow),
         :ok <- validate_agents(entry.agents) do
      :ok
    else
      {:error, %Error{} = error} ->
        {:error,
         Error.new(:input_error, :invalid_shell, "invalid scaffold",
           details: %{path: path, error: Error.to_map(error)}
         )}
    end
  end

  defp namespace_for(:builtin), do: "builtin"
  defp namespace_for(:local), do: "local"

  defp shell_paths_in_dir(dir) do
    @formats
    |> Enum.flat_map(fn {_format, extensions} -> extensions end)
    |> Enum.flat_map(&Path.wildcard(Path.join(dir, "**/*#{&1}")))
    |> Enum.sort()
  end

  defp format_for_path(path) do
    extension = path |> Path.extname() |> String.downcase()

    case Enum.find(@formats, fn {_format, extensions} -> extension in extensions end) do
      {format, _extensions} ->
        {:ok, format}

      nil ->
        {:error,
         Error.new(:input_error, :invalid_shell, "unsupported scaffold extension",
           details: %{path: path, extension: extension}
         )}
    end
  end

  defp maybe_mock_agents(workflow, opts) do
    if Keyword.get(opts, :with_mock_agents?, false) do
      workflow
      |> Map.fetch!("shots")
      |> Enum.map(&Map.get(&1, "agent"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&mock_agent/1)
    else
      []
    end
  end

  defp mock_agent(agent_id) do
    %{
      "kind" => "agent",
      "id" => agent_id,
      "name" => titleize(agent_id),
      "version" => "1.0.0",
      "provider" => "mock",
      "model" => "mock-model",
      "system_prompt" => "You are #{agent_id}. Return concise JSON matching the shot schema.",
      "tools" => %{"allowed" => ["kubectl_get", "kubectl_apply"]}
    }
  end

  defp put_generated_metadata(workflow, entry) do
    source =
      %{
        "kind" => "scaffold",
        "namespace" => entry.namespace,
        "id" => entry.id,
        "version" => entry.version,
        "digest" => entry.digest,
        "hash" => entry.digest,
        "path" => entry.path
      }
      |> compact()

    Map.put(workflow, "metadata", %{
      "lifecycle" => "draft",
      "generated_by" => %{
        "tool" => "twelvgaige",
        "command" => "shell new",
        "version" => Twelvgaige.version(),
        "source" => source
      }
    })
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
         Error.new(:input_error, :invalid_shell, "scaffold outdated scan path does not exist",
           details: %{path: expanded}
         )}
    end
  end

  defp scan_scaffold_usage(paths, scaffolds) do
    scaffolds_by_key = Map.new(scaffolds, &{entry_key(&1), &1})

    scan =
      Enum.reduce(paths, %{checked_workflows: 0, findings: [], errors: []}, fn path, acc ->
        case Loader.load(path) do
          {:ok, %Workflow{} = workflow} ->
            scan_workflow(path, workflow, scaffolds_by_key, acc)

          {:ok, _agent} ->
            acc

          {:error, %Error{} = error}
          when error.message == "shell kind must be workflow or agent" ->
            acc

          {:error, %Error{} = error} ->
            update_in(acc.errors, &[%{"path" => path, "error" => Error.to_map(error)} | &1])
        end
      end)

    {:ok, %{scan | findings: Enum.reverse(scan.findings), errors: Enum.reverse(scan.errors)}}
  end

  defp scan_workflow(path, %Workflow{} = workflow, scaffolds_by_key, acc) do
    acc = %{acc | checked_workflows: acc.checked_workflows + 1}

    case get_in(workflow.metadata.generated_by, ["source"]) do
      %{"kind" => "scaffold"} = source ->
        findings = scaffold_source_findings(path, workflow, source, scaffolds_by_key)
        update_in(acc.findings, &(Enum.reverse(findings) ++ &1))

      _other ->
        acc
    end
  end

  defp scaffold_source_findings(path, workflow, source, scaffolds_by_key) do
    key = source_key(source)

    cond do
      is_nil(key) ->
        [scaffold_usage_finding("scaffold_source_invalid", path, workflow, source, nil)]

      is_nil(source_digest(source)) ->
        [scaffold_usage_finding("source_digest_missing", path, workflow, source, key)]

      scaffold = Map.get(scaffolds_by_key, key) ->
        []
        |> maybe_digest_mismatch(path, workflow, source, key, scaffold)
        |> maybe_version_mismatch(path, workflow, source, key, scaffold)

      true ->
        [scaffold_usage_finding("scaffold_missing", path, workflow, source, key)]
    end
  end

  defp maybe_digest_mismatch(findings, path, workflow, source, key, scaffold) do
    if source_digest(source) == scaffold.digest do
      findings
    else
      [
        scaffold_usage_finding("digest_mismatch", path, workflow, source, key, %{
          "current_digest" => scaffold.digest
        })
        | findings
      ]
    end
  end

  defp maybe_version_mismatch(findings, path, workflow, source, key, scaffold) do
    source_version = Map.get(source, "version")

    if is_nil(source_version) or source_version == scaffold.version do
      findings
    else
      [
        scaffold_usage_finding("version_mismatch", path, workflow, source, key, %{
          "current_version" => scaffold.version
        })
        | findings
      ]
    end
  end

  defp scaffold_usage_finding(status, path, workflow, source, scaffold, extra \\ %{}) do
    %{
      "status" => status,
      "message" => scaffold_usage_message(status),
      "path" => path,
      "workflow" => workflow.id,
      "scaffold" => scaffold,
      "source_digest" => source_digest(source),
      "source_version" => Map.get(source, "version")
    }
    |> Map.merge(extra)
    |> compact()
  end

  defp scaffold_usage_message("digest_mismatch"),
    do: "generated workflow scaffold digest is outdated"

  defp scaffold_usage_message("version_mismatch"),
    do: "generated workflow scaffold version is outdated"

  defp scaffold_usage_message("scaffold_missing"),
    do: "generated workflow references a missing scaffold"

  defp scaffold_usage_message("source_digest_missing"),
    do: "generated workflow scaffold source is missing a digest"

  defp scaffold_usage_message("scaffold_source_invalid"),
    do: "generated workflow scaffold source is invalid"

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

  defp write_lockfile(lockfile, scaffolds) do
    with {:ok, contents} <- lockfile_candidate(lockfile, scaffolds),
         :ok <- AtomicFile.write(lockfile, contents) do
      {:ok,
       %{
         "kind" => "twelvgaige.scaffold_verify",
         "status" => "ok",
         "mode" => "write_lock",
         "lockfile" => lockfile,
         "checked" => length(scaffolds),
         "findings" => [],
         "exit_code" => 0
       }}
    end
  end

  defp verify_lockfile(lockfile, scaffolds) do
    with {:ok, lock} <- load_lockfile(lockfile) do
      findings = lock_findings(lockfile, scaffolds, lock)
      status = if findings == [], do: "ok", else: "failed"

      {:ok,
       %{
         "kind" => "twelvgaige.scaffold_verify",
         "status" => status,
         "mode" => "verify",
         "lockfile" => lockfile,
         "checked" => length(scaffolds),
         "findings" => findings,
         "exit_code" => if(status == "ok", do: 0, else: 4)
       }}
    end
  end

  defp update_report_kind, do: "twelvgaige.scaffold_update"

  defp library_update_report(lockfile, scaffolds, findings, changed?, mode, diff) do
    %{
      "kind" => update_report_kind(),
      "status" => "ok",
      "mode" => mode,
      "lockfile" => lockfile,
      "checked" => length(scaffolds),
      "changed" => changed?,
      "findings" => findings,
      "diff" => diff,
      "exit_code" => 0
    }
    |> compact()
  end

  defp lockfile_candidate(lockfile, scaffolds) do
    with {:ok, preserved_entries} <- preserved_lock_entries(lockfile, "scaffold") do
      lockfile
      |> lock_document(scaffolds, preserved_entries)
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
         Error.new(:input_error, :invalid_shell, "unable to read scaffold lockfile",
           details: %{lockfile: lockfile, reason: inspect(reason)}
         )}
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
           "entries" => [%{"status" => "missing_lockfile", "source" => lockfile}]
         }}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:input_error, :invalid_shell, "unable to read scaffold lockfile",
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

  defp lock_document(lockfile, scaffolds, preserved_entries) do
    %{
      "kind" => "library_lock",
      "version" => 1,
      "entries" =>
        (preserved_entries ++ Enum.map(scaffolds, &lock_entry(lockfile, &1)))
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

  defp lock_entry(lockfile, scaffold) do
    %{
      "kind" => "scaffold",
      "namespace" => scaffold.namespace,
      "id" => scaffold.id,
      "version" => scaffold.version,
      "source" => relative_source(lockfile, scaffold.path),
      "digest" => scaffold.digest
    }
  end

  defp lock_findings(lockfile, _scaffolds, %{"entries" => [%{"status" => "missing_lockfile"}]}) do
    [
      %{
        "status" => "missing_lockfile",
        "message" => "library lockfile does not exist",
        "lockfile" => lockfile
      }
    ]
  end

  defp lock_findings(lockfile, scaffolds, %{"entries" => entries}) do
    scaffold_entries = Enum.filter(entries, &(Map.get(&1, "kind") == "scaffold"))
    entries_by_key = Map.new(scaffold_entries, &{entry_key(&1), &1})
    scaffolds_by_key = Map.new(scaffolds, &{entry_key(&1), &1})

    missing_entries =
      scaffolds
      |> Enum.flat_map(fn scaffold ->
        case Map.fetch(entries_by_key, entry_key(scaffold)) do
          {:ok, entry} -> digest_finding(lockfile, scaffold, entry)
          :error -> [missing_lock_entry(scaffold)]
        end
      end)

    stale_entries =
      scaffold_entries
      |> Enum.flat_map(fn entry ->
        case Map.fetch(scaffolds_by_key, entry_key(entry)) do
          {:ok, _scaffold} -> []
          :error -> [missing_scaffold(lockfile, entry)]
        end
      end)

    missing_entries ++ stale_entries
  end

  defp digest_finding(_lockfile, scaffold, %{"digest" => digest})
       when digest == scaffold.digest,
       do: []

  defp digest_finding(lockfile, scaffold, entry) do
    [
      %{
        "status" => "digest_mismatch",
        "message" => "scaffold digest does not match library lock",
        "scaffold" => entry_key(scaffold),
        "source" => relative_source(lockfile, scaffold.path),
        "expected_digest" => Map.get(entry, "digest"),
        "actual_digest" => scaffold.digest
      }
    ]
  end

  defp missing_lock_entry(scaffold) do
    %{
      "status" => "missing_lock_entry",
      "message" => "scaffold is not present in the library lock",
      "scaffold" => entry_key(scaffold),
      "digest" => scaffold.digest,
      "source" => scaffold.path
    }
  end

  defp missing_scaffold(lockfile, entry) do
    %{
      "status" => "missing_scaffold",
      "message" => "library lock references a missing scaffold",
      "scaffold" => entry_key(entry),
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

  defp validate_workflow_id(workflow_id) do
    case Workflow.from_map(%{
           "kind" => "workflow",
           "id" => workflow_id,
           "version" => "1.0.0",
           "shots" => [%{"id" => "validate", "kind" => "slug", "agent" => "agent"}]
         }) do
      {:ok, _workflow} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_workflow(workflow) do
    case Workflow.from_map(workflow) do
      {:ok, _workflow} -> {:ok, workflow}
      {:error, _reason} = error -> error
    end
  end

  defp validate_agents(agents) do
    Enum.reduce_while(agents, :ok, fn agent, :ok ->
      case Agent.from_map(agent) do
        {:ok, _agent} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp summary_schema do
    %{
      "type" => "object",
      "required" => ["summary"],
      "properties" => %{"summary" => %{"type" => "string"}}
    }
  end

  defp prompt_with_example(prompt, example) do
    """
    #{prompt}

    Return JSON matching this shape. Example:

    ```json
    #{Jason.encode!(example)}
    ```
    """
    |> String.trim()
  end

  defp titleize(value) do
    value
    |> String.replace(["_", "-"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp source_digest(source), do: Map.get(source, "digest") || Map.get(source, "hash")

  defp source_key(%{"namespace" => namespace, "id" => id})
       when is_binary(namespace) and is_binary(id),
       do: "#{namespace}/#{id}"

  defp source_key(%{"id" => id}) when is_binary(id) do
    if String.contains?(id, "/"), do: id, else: "builtin/#{id}"
  end

  defp source_key(_source), do: nil

  defp relative_source(_lockfile, nil), do: nil
  defp relative_source(lockfile, path), do: Path.relative_to(path, Path.dirname(lockfile))
  defp entry_key(%{namespace: namespace, id: id}), do: "#{namespace}/#{id}"
  defp entry_key(entry), do: "#{Map.get(entry, "namespace", "local")}/#{Map.get(entry, "id")}"

  defp known_scaffold_names(scaffolds) do
    local =
      scaffolds
      |> Enum.reject(&(&1.source == :builtin))
      |> Enum.map(&entry_key/1)
      |> Enum.sort()

    names() ++ local
  end

  defp digest(map) do
    encoded = :erlang.term_to_binary(map)
    "sha256:" <> (:crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower))
  end

  defp required_string(map, key, path) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        {:error,
         Error.new(:input_error, :invalid_shell, "scaffold #{key} must be a non-empty string",
           details: %{path: path, key: key}
         )}
    end
  end

  defp required_map(map, key, path) do
    case Map.get(map, key) do
      value when is_map(value) ->
        {:ok, value}

      _other ->
        {:error,
         Error.new(:input_error, :invalid_shell, "scaffold #{key} must be a map",
           details: %{path: path, key: key}
         )}
    end
  end

  defp optional_list(map, key, path) do
    case Map.get(map, key, []) do
      value when is_list(value) ->
        {:ok, value}

      _other ->
        {:error,
         Error.new(:input_error, :invalid_shell, "scaffold #{key} must be a list",
           details: %{path: path, key: key}
         )}
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] or value == %{} end)
    |> Map.new()
  end
end
