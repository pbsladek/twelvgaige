defmodule Twelvgaige.Platform do
  @moduledoc "Supported host-platform policy."

  @type os_type :: {:unix | :win32, atom()}

  @spec ensure_supported(os_type()) :: :ok | {:error, {:unsupported_platform, atom()}}
  def ensure_supported(os_type \\ :os.type())
  def ensure_supported({:unix, :darwin}), do: :ok
  def ensure_supported({:unix, :linux}), do: :ok
  def ensure_supported({:win32, _name}), do: {:error, {:unsupported_platform, :windows}}
  def ensure_supported({_family, name}), do: {:error, {:unsupported_platform, name}}
end
