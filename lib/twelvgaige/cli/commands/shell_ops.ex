defmodule Twelvgaige.CLI.Commands.ShellOps do
  @moduledoc false

  alias Twelvgaige.CLI.Commands.ShellAnalysisOps
  alias Twelvgaige.CLI.Commands.ShellDocumentOps

  defdelegate normalize(path, args), to: ShellDocumentOps
  defdelegate convert(path, args), to: ShellDocumentOps
  defdelegate fmt(path, args), to: ShellDocumentOps
  defdelegate graph(path, args), to: ShellAnalysisOps
  defdelegate lint(path, args), to: ShellAnalysisOps
  defdelegate admit(path, args), to: ShellAnalysisOps
  defdelegate doctor(path, args), to: ShellAnalysisOps
end
