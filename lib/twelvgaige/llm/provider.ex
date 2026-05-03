defmodule Twelvgaige.LLM.Provider do
  @moduledoc """
  Behaviour implemented by LLM provider adapters.
  """

  @callback provider_id() :: String.t()
  @callback capabilities(config :: map()) :: Twelvgaige.LLM.Capabilities.t()
  @callback complete(model :: String.t(), messages :: [map()], opts :: keyword()) ::
              {:ok, Twelvgaige.LLM.Response.t()} | {:error, Twelvgaige.Error.t()}

  @spec provider?(module()) :: boolean()
  def provider?(module) when is_atom(module) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get(:behaviour, [])

    __MODULE__ in behaviours
  rescue
    UndefinedFunctionError -> false
  end
end
