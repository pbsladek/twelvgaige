defmodule Twelvgaige.Event.Buffer do
  @moduledoc """
  Bounded priority buffer for protocol and presentation events.

  Critical control events have reserved capacity and are always drained first.
  Presentation deltas coalesce by key, preventing streaming floods from growing
  a controller mailbox without bound.
  """

  alias Twelvgaige.Round.Event

  @enforce_keys [:capacity, :critical_reserve]
  defstruct capacity: 256,
            critical_reserve: 32,
            critical: [],
            operational: [],
            presentation_order: [],
            presentation: %{},
            dropped_presentation: 0,
            overloads: 0

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    capacity = Keyword.get(opts, :capacity, 256)
    reserve = Keyword.get(opts, :critical_reserve, min(32, capacity))

    if not is_integer(capacity) or capacity <= 0 or not is_integer(reserve) or reserve <= 0 or
         reserve > capacity do
      raise ArgumentError, "invalid event buffer capacity or critical reserve"
    end

    %__MODULE__{capacity: capacity, critical_reserve: reserve}
  end

  @spec push(t(), term(), keyword()) :: {:ok, t()} | {:overload, t(), atom()}
  def push(%__MODULE__{} = buffer, event, opts \\ []) do
    class = Keyword.get(opts, :class, event_class(event))

    case class do
      :critical -> push_critical(buffer, event)
      :operational -> push_operational(buffer, event)
      :presentation -> push_presentation(buffer, event, Keyword.get(opts, :coalesce_key))
    end
  end

  @spec pop(t()) :: {:ok, term(), t()} | :empty
  def pop(%__MODULE__{critical: [event | rest]} = buffer),
    do: {:ok, event, %{buffer | critical: rest}}

  def pop(%__MODULE__{operational: [event | rest]} = buffer),
    do: {:ok, event, %{buffer | operational: rest}}

  def pop(%__MODULE__{presentation_order: [key | rest]} = buffer) do
    {event, presentation} = Map.pop(buffer.presentation, key)
    {:ok, event, %{buffer | presentation_order: rest, presentation: presentation}}
  end

  def pop(%__MODULE__{}), do: :empty

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = buffer) do
    length(buffer.critical) + length(buffer.operational) + map_size(buffer.presentation)
  end

  @spec stats(t()) :: map()
  def stats(%__MODULE__{} = buffer) do
    %{
      size: size(buffer),
      critical: length(buffer.critical),
      operational: length(buffer.operational),
      presentation: map_size(buffer.presentation),
      dropped_presentation: buffer.dropped_presentation,
      overloads: buffer.overloads
    }
  end

  defp push_critical(buffer, event) do
    buffer = make_room_for_critical(buffer)

    if size(buffer) < buffer.capacity do
      {:ok, %{buffer | critical: buffer.critical ++ [event]}}
    else
      {:overload, %{buffer | overloads: buffer.overloads + 1}, :critical_capacity_exhausted}
    end
  end

  defp push_operational(buffer, event) do
    noncritical_limit = buffer.capacity - buffer.critical_reserve
    noncritical_size = length(buffer.operational) + map_size(buffer.presentation)

    if size(buffer) < buffer.capacity and noncritical_size < noncritical_limit do
      {:ok, %{buffer | operational: buffer.operational ++ [event]}}
    else
      {:overload, %{buffer | overloads: buffer.overloads + 1}, :operational_capacity_exhausted}
    end
  end

  defp push_presentation(buffer, event, nil),
    do: push_presentation(buffer, event, presentation_key(event))

  defp push_presentation(buffer, event, key) do
    cond do
      Map.has_key?(buffer.presentation, key) ->
        {:ok, put_in(buffer.presentation[key], event)}

      noncritical_room?(buffer) ->
        {:ok,
         %{
           buffer
           | presentation: Map.put(buffer.presentation, key, event),
             presentation_order: buffer.presentation_order ++ [key]
         }}

      true ->
        {:ok, %{buffer | dropped_presentation: buffer.dropped_presentation + 1}}
    end
  end

  defp noncritical_room?(buffer) do
    noncritical_limit = buffer.capacity - buffer.critical_reserve

    size(buffer) < buffer.capacity and
      length(buffer.operational) + map_size(buffer.presentation) < noncritical_limit
  end

  defp make_room_for_critical(%__MODULE__{} = buffer) do
    cond do
      size(buffer) < buffer.capacity -> buffer
      buffer.presentation_order != [] -> drop_oldest_presentation(buffer)
      buffer.operational != [] -> %{buffer | operational: tl(buffer.operational)}
      true -> buffer
    end
  end

  defp drop_oldest_presentation(buffer) do
    [key | rest] = buffer.presentation_order

    %{
      buffer
      | presentation_order: rest,
        presentation: Map.delete(buffer.presentation, key),
        dropped_presentation: buffer.dropped_presentation + 1
    }
  end

  defp event_class(%Event{event_class: class}), do: class
  defp event_class(%{event_class: class}), do: normalize_class(class)
  defp event_class(%{"event_class" => class}), do: normalize_class(class)
  defp event_class(%{event_type: type}), do: Event.classify(type)
  defp event_class(%{"event_type" => type}), do: Event.classify(type)
  defp event_class(_event), do: :operational

  defp normalize_class(class) when class in [:critical, :operational, :presentation], do: class
  defp normalize_class("critical"), do: :critical
  defp normalize_class("operational"), do: :operational
  defp normalize_class("presentation"), do: :presentation

  defp presentation_key(%Event{shot_id: shot_id, event_type: type}), do: {shot_id, type}
  defp presentation_key(%{shot_id: shot_id, event_type: type}), do: {shot_id, type}
  defp presentation_key(%{"shot_id" => shot_id, "event_type" => type}), do: {shot_id, type}
  defp presentation_key(event), do: {:presentation, :erlang.phash2(event)}
end
