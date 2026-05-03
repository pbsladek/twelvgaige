defmodule Twelvgaige.Tool.ExecutorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.ResourceLimiter
  alias Twelvgaige.Tool.Executor
  alias Twelvgaige.Tool.Idempotency

  defmodule DestructiveTool do
    @behaviour Twelvgaige.Tool

    def name, do: "destructive_test"
    def description, do: "test destructive tool"
    def input_schema, do: %{"type" => "object", "additionalProperties" => false}
    def safety_level, do: :destructive
    def idempotency, do: Idempotency.non_idempotent()
    def execute(_input, _opts), do: {:ok, %{"ok" => true}}
  end

  defmodule SlowTool do
    @behaviour Twelvgaige.Tool

    def name, do: "slow_test"
    def description, do: "test slow tool"
    def input_schema, do: %{"type" => "object", "additionalProperties" => false}
    def safety_level, do: :read_only
    def idempotency, do: Idempotency.read_only()

    def execute(_input, _opts) do
      Process.sleep(5_000)
      {:ok, %{"ok" => true}}
    end
  end

  defmodule LargeTool do
    @behaviour Twelvgaige.Tool

    def name, do: "large_test"
    def description, do: "test large output"
    def input_schema, do: %{"type" => "object", "additionalProperties" => false}
    def safety_level, do: :read_only
    def idempotency, do: Idempotency.read_only()
    def execute(_input, _opts), do: {:ok, %{"body" => String.duplicate("x", 100)}}
  end

  defmodule TestCatalog do
    def fetch("destructive_test"), do: {:ok, DestructiveTool}
    def fetch("slow_test"), do: {:ok, SlowTool}
    def fetch("large_test"), do: {:ok, LargeTool}
    def fetch(name), do: Twelvgaige.Tool.Catalog.fetch(name)
  end

  test "denies tools not explicitly allowlisted before execution" do
    assert {:error, error} = Executor.execute("shell_read", %{"path" => "x"}, limiter: nil)

    assert error.reason == :tool_denied
    assert error.safety_required
  end

  test "returns unknown_tool for missing catalog entries" do
    assert {:error, error} =
             Executor.execute("missing", %{},
               allowed_tools: ["missing"],
               limiter: nil
             )

    assert error.reason == :unknown_tool
  end

  test "validates tool input before execution" do
    assert {:error, error} =
             Executor.execute("shell_read", %{},
               allowed_tools: ["shell_read"],
               limiter: nil
             )

    assert error.reason == :tool_input_invalid
  end

  test "enforces safety threshold" do
    assert {:error, error} =
             Executor.execute("destructive_test", %{},
               allowed_tools: ["destructive_test"],
               catalog: TestCatalog,
               limiter: nil,
               max_safety: :read_only
             )

    assert error.class == :policy_error
    assert error.reason == :policy_denied
    assert error.details.tool_safety == :destructive
  end

  test "classifies tool timeout" do
    assert {:error, error} =
             Executor.execute("slow_test", %{},
               allowed_tools: ["slow_test"],
               catalog: TestCatalog,
               limiter: nil,
               timeout_ms: 1
             )

    assert error.reason == :tool_timeout
    assert error.retryable
  end

  test "enforces generic output byte limit" do
    assert {:error, error} =
             Executor.execute("large_test", %{},
               allowed_tools: ["large_test"],
               catalog: TestCatalog,
               limiter: nil,
               max_output_bytes: 20
             )

    assert error.reason == :output_too_large
  end

  test "acquires and releases resource limiter permits" do
    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{tool_exec: 1}})
    root = tmp_dir!()
    file = Path.join(root, "note.txt")
    File.write!(file, "hello")

    assert {:ok, %{"content" => "hello"}} =
             Executor.execute("shell_read", %{"path" => "note.txt"},
               allowed_tools: ["shell_read"],
               limiter: limiter,
               tool_opts: [root: root]
             )

    assert ResourceLimiter.snapshot(limiter).used.tool_exec == 0
  end

  defp tmp_dir! do
    path = Path.join(System.tmp_dir!(), "twelvgaige-tool-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
