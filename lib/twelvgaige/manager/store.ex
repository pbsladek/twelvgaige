defmodule Twelvgaige.Manager.Store do
  @moduledoc "Durable, idempotent manager plan/child/event storage contract."

  @callback put_plan(map(), keyword()) :: :ok | :already_present | {:error, term()}
  @callback put_submission(map(), [struct()], keyword()) ::
              :ok | :already_present | {:error, term()}
  @callback get_plan(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  @callback list_plans(keyword()) :: {:ok, [map()]}
  @callback update_plan(String.t(), non_neg_integer(), map(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback put_child(struct(), keyword()) :: :ok | :already_present | {:error, term()}
  @callback get_child(String.t(), keyword()) :: {:ok, struct()} | {:error, :not_found}
  @callback list_children(String.t(), keyword()) :: {:ok, [struct()]}
  @callback update_child(String.t(), non_neg_integer(), map(), keyword()) ::
              {:ok, struct()} | {:error, term()}
  @callback append_event(String.t(), map(), keyword()) ::
              :ok | :already_present | {:error, term()}
  @callback list_events(String.t(), keyword()) :: {:ok, [map()]}
end
