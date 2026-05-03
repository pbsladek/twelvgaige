defmodule Twelvgaige.Security do
  @moduledoc false

  import Bitwise

  @spec secure_equal?(term(), term()) :: boolean()
  def secure_equal?(left, right)
      when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    if function_exported?(:crypto, :hash_equals, 2) do
      :crypto.hash_equals(left, right)
    else
      constant_time_equal?(left, right)
    end
  end

  def secure_equal?(_left, _right), do: false

  defp constant_time_equal?(left, right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {left_byte, right_byte}, acc -> acc ||| bxor(left_byte, right_byte) end)
    |> Kernel.==(0)
  end
end
