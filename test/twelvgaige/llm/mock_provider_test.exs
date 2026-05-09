defmodule Twelvgaige.LLM.MockProviderTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.LLM

  setup do
    previous = System.get_env("TWELVGAIGE_MOCK_RESPONSES_FILE")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("TWELVGAIGE_MOCK_RESPONSES_FILE")
        value -> System.put_env("TWELVGAIGE_MOCK_RESPONSES_FILE", value)
      end
    end)

    :ok
  end

  test "mock provider can read scripted responses by iteration for CLI e2e" do
    root = Path.join(System.tmp_dir!(), "twelvgaige-mock-provider-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    path = Path.join(root, "responses.json")

    File.write!(path, Jason.encode!([%{content: "first"}, %{content: "second"}]))
    System.put_env("TWELVGAIGE_MOCK_RESPONSES_FILE", path)

    assert {:ok, first} = LLM.complete(:mock, "mock-model", [], mock_iteration: 0)
    assert {:ok, second} = LLM.complete(:mock, "mock-model", [], mock_iteration: 1)

    assert first.content == "first"
    assert second.content == "second"
  end

  test "mock provider can read scripted responses by shot id" do
    root = Path.join(System.tmp_dir!(), "twelvgaige-mock-provider-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    path = Path.join(root, "responses.json")

    File.write!(
      path,
      Jason.encode!(%{
        responses_by_shot: %{
          "inspect" => [%{content: "inspect first"}, %{content: "inspect second"}],
          "verify" => [%{content: "verify first"}]
        }
      })
    )

    System.put_env("TWELVGAIGE_MOCK_RESPONSES_FILE", path)

    assert {:ok, inspect_first} =
             LLM.complete(:mock, "mock-model", [],
               limiter_context: %{shot_id: "inspect"},
               mock_iteration: 0
             )

    assert {:ok, inspect_second} =
             LLM.complete(:mock, "mock-model", [],
               limiter_context: %{shot_id: "inspect"},
               mock_iteration: 1
             )

    assert {:ok, verify_first} =
             LLM.complete(:mock, "mock-model", [],
               limiter_context: %{shot_id: "verify"},
               mock_iteration: 0
             )

    assert inspect_first.content == "inspect first"
    assert inspect_second.content == "inspect second"
    assert verify_first.content == "verify first"
  end
end
