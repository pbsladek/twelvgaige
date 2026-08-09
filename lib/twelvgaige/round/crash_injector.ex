defmodule Twelvgaige.Round.CrashInjector do
  @moduledoc "Deterministic transition crash hook used by recovery fault-injection suites."

  defmodule InjectedCrash do
    defexception [:stage, :event_type, :transition_id]

    @impl true
    def message(error) do
      "injected crash #{error.stage} #{error.event_type} transition=#{error.transition_id}"
    end
  end

  @spec hook(keyword()) :: (atom(), map(), term() -> :ok)
  def hook(opts) do
    stage = Keyword.fetch!(opts, :stage)
    event_type = Keyword.get(opts, :event_type)
    occurrence = Keyword.get(opts, :occurrence, 1)
    counter = :counters.new(1, [:atomics])

    fn actual_stage, pending, _state ->
      matches? =
        actual_stage == stage and
          (is_nil(event_type) or pending.event_type == event_type)

      if matches? do
        :ok = :counters.add(counter, 1, 1)
        count = :counters.get(counter, 1)

        if count == occurrence do
          raise InjectedCrash,
            stage: actual_stage,
            event_type: pending.event_type,
            transition_id: pending.transition_id
        end
      end

      :ok
    end
  end
end
