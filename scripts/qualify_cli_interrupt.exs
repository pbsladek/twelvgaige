alias Twelvgaige.CLI.InterruptSource

parent = self()

case InterruptSource.start(fn -> send(parent, :terminal_interrupt) end) do
  {:ok, source} when is_map(source) ->
    try do
      IO.puts("interrupt-ready")

      Enum.each(1..2, fn index ->
        receive do
          :terminal_interrupt -> IO.puts("interrupt-#{index}")
        after
          5_000 ->
            IO.puts(:stderr, "Timed out waiting for interrupt #{index}")
            System.halt(1)
        end
      end)
    after
      InterruptSource.stop(source)
    end

  {:ok, nil} ->
    IO.puts(:stderr, "Interrupt FIFO was not provided")
    System.halt(1)

  {:error, reason} ->
    IO.puts(:stderr, "Interrupt source failed: #{inspect(reason)}")
    System.halt(1)
end
