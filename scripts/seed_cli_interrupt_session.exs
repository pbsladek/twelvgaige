alias Twelvgaige.Operations.{Paths, SessionControl, Store}

args = Enum.drop_while(System.argv(), &(&1 == "--"))

case args do
  [data_root, session_id] ->
    {:ok, store} =
      Store.start_link(
        name: nil,
        path: Paths.operations_database(data_root: data_root)
      )

    {:ok, control} =
      SessionControl.start_link(
        name: nil,
        store: store,
        artifact_store: nil,
        workspace_root: Paths.workspaces(data_root: data_root)
      )

    {:ok, %{id: ^session_id, status: :running}} =
      SessionControl.register(
        %{
          id: session_id,
          request_id: "req_cli_interrupt_seed",
          plan_id: "plan_cli_interrupt",
          child_id: "child_cli_interrupt",
          status: :running,
          repository: "qualification-fixture",
          workspace_id: "ws_cli_interrupt",
          control_epoch: 1
        },
        server: control
      )

    GenServer.stop(control)
    GenServer.stop(store)

  _other ->
    raise "usage: mix run scripts/seed_cli_interrupt_session.exs -- DATA_ROOT SESSION_ID"
end
