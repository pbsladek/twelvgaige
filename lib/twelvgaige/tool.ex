defmodule Twelvgaige.Tool do
  @moduledoc """
  Behaviour implemented by executable tools.

  A tool is deliberately narrower than an agent. It declares stable metadata,
  an input schema, safety/idempotency properties, and a single bounded
  `execute/2` callback. Permission checks, input validation, resource
  admission, timeout handling, and output size checks live in
  `Twelvgaige.Tool.Executor`, not in individual tools.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback safety_level() :: Twelvgaige.Tool.Safety.level()
  @callback idempotency() :: Twelvgaige.Tool.Idempotency.t()
  @callback execute(input :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, Twelvgaige.Error.t() | term()}
end
