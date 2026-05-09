defmodule Twelvgaige.Authoring.ShotRefactor.ValidationTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Authoring.ShotRefactor.Validation
  alias Twelvgaige.Error

  test "detects supported workflow file formats by extension" do
    assert {:ok, :yaml} = Validation.format_for_path("workflow.yaml")
    assert {:ok, :yaml} = Validation.format_for_path("workflow.yml")
    assert {:ok, :json} = Validation.format_for_path("workflow.json")
    assert {:ok, :toml} = Validation.format_for_path("workflow.toml")
  end

  test "rejects unsupported workflow extensions with input errors" do
    assert {:error, %Error{class: :input_error, reason: :invalid_shell} = error} =
             Validation.format_for_path("workflow.txt")

    assert error.details == %{extension: ".txt"}
  end

  test "builds a compact line-oriented diff preview" do
    assert """
           --- workflow.yaml
           +++ workflow.yaml
           @@
            id: demo
           -shots: []
           +shots:
           +- id: first
           """ =
             Validation.unified_diff(
               "workflow.yaml",
               "id: demo\nshots: []\n",
               "id: demo\nshots:\n- id: first\n"
             )
  end
end
