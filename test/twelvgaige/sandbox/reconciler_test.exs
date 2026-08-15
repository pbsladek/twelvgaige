defmodule Twelvgaige.Sandbox.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Sandbox.Reconciler

  defmodule Backend do
    def reconcile(%{resource_id: "resume", manifest: manifest}, opts),
      do: {:ok, :resume, %{manifest: manifest, marker: opts[:marker]}}

    def reconcile(%{resource_id: "missing"}, _opts), do: {:ok, :missing, %{}}
    def reconcile(%{resource_id: "error"}, _opts), do: {:error, :inspection_failed}
    def reconcile(%{resource_id: "invalid"}, _opts), do: {:ok, :running, %{}}
  end

  test "normalizes backend decisions and quarantines reconciliation errors" do
    records = %{
      "resume" => %{manifest: %{digest: "one"}},
      "missing" => %{manifest: %{digest: "two"}},
      "error" => %{manifest: %{digest: "three"}},
      "invalid" => %{manifest: %{digest: "four"}}
    }

    assert %{
             "resume" => %{
               status: :resume,
               observed: %{manifest: %{digest: "one"}, marker: :seen}
             },
             "missing" => %{status: :missing, observed: %{}},
             "error" => %{status: :quarantine, reason: :inspection_failed},
             "invalid" => %{
               status: :quarantine,
               reason: {:invalid_reconciliation_response, {:ok, :running, %{}}}
             }
           } = Reconciler.reconcile(records, Backend, marker: :seen)
  end

  test "quarantines managed resources that have no durable record" do
    assert %{
             "orphan-a" => %{status: :quarantine, reason: :unknown_managed_resource},
             "orphan-b" => %{status: :quarantine, reason: :unknown_managed_resource}
           } = Reconciler.classify_unknown(["known", "orphan-a", "orphan-b"], %{"known" => %{}})
  end
end
