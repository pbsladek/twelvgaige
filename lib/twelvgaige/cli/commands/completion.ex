defmodule Twelvgaige.CLI.Commands.Completion do
  @moduledoc false

  alias Twelvgaige.CLI.CompletionCandidates

  def run([shell]) when shell in ["bash", "zsh", "fish"] do
    {:ok, script(shell), 0}
  end

  def run(["candidates", kind | args])
      when kind in ["command", "profile", "session", "workspace"] do
    with {:ok, opts} <- candidate_options(args, []),
         {:ok, candidates} <- CompletionCandidates.list(String.to_existing_atom(kind), opts) do
      {:ok, Enum.map_join(candidates, "", &(&1 <> "\n")), 0}
    else
      {:error, reason} -> error(reason)
    end
  end

  def run([]), do: error(:completion_shell_required)
  def run([shell]), do: error({:completion_shell_unsupported, shell})
  def run(_args), do: error(:completion_arguments_invalid)

  defp script("bash") do
    """
    _twelvgaige_complete() {
      local cur candidate i
      local -a query
      COMPREPLY=()
      cur="${COMP_WORDS[COMP_CWORD]}"
      query=(completion candidates command --current "$cur")
      for ((i = 1; i < COMP_CWORD; i++)); do
        query+=(--word "${COMP_WORDS[i]}")
      done
      while IFS= read -r candidate; do
        [[ -n "$candidate" ]] && COMPREPLY+=("$candidate")
      done < <(command twelvgaige "${query[@]}" 2>/dev/null)
    }
    complete -o default -F _twelvgaige_complete twelvgaige
    """
  end

  defp script("zsh") do
    """
    #compdef twelvgaige
    _twelvgaige() {
      local -a query candidates
      local i
      query=(completion candidates command --current "$PREFIX")
      for ((i = 2; i < CURRENT; i++)); do
        query+=(--word "$words[i]")
      done
      candidates=("${(@f)$(command twelvgaige "${query[@]}" 2>/dev/null)}")
      if (( ${#candidates[@]} )); then
        compadd -a candidates
      else
        _files
      fi
    }
    compdef _twelvgaige twelvgaige
    """
  end

  defp script("fish") do
    """
    function __twelvgaige_complete
      set -l query completion candidates command --current (commandline -ct)
      set -l tokens (commandline -opc)
      for word in $tokens[2..-1]
        set -a query --word $word
      end
      command twelvgaige $query 2>/dev/null
    end
    complete -c twelvgaige -a '(__twelvgaige_complete)'
    """
  end

  defp candidate_options([], opts), do: {:ok, opts}

  defp candidate_options(["--root", value | rest], opts),
    do: candidate_options(rest, Keyword.put(opts, :project_root, value))

  defp candidate_options(["--data-root", value | rest], opts),
    do: candidate_options(rest, Keyword.put(opts, :data_root, value))

  defp candidate_options(["--current", value | rest], opts),
    do: candidate_options(rest, Keyword.put(opts, :current, value))

  defp candidate_options(["--word", value | rest], opts),
    do: candidate_options(rest, Keyword.update(opts, :words, [value], &(&1 ++ [value])))

  defp candidate_options([unknown | _rest], _opts),
    do: {:error, {:completion_candidate_option_invalid, unknown}}

  defp error(reason) do
    message = "completion generation failed: #{inspect(reason)}\n"
    {:ok, message, 4}
  end
end
