defmodule Twelvgaige.Breech.IPC.ClientTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Breech.IPC.Client
  alias Twelvgaige.Breech.IPC.Endpoint

  test "TCP endpoint addresses round-trip IPv4 and bracketed IPv6 hosts" do
    ipv4 = {:tcp, {127, 0, 0, 1}, 44_321}
    ipv6 = {:tcp, {0, 0, 0, 0, 0, 0, 0, 1}, 44_322}

    assert Endpoint.address_to_string(ipv4) == "tcp://127.0.0.1:44321"
    assert Client.parse_address(Endpoint.address_to_string(ipv4)) == {:ok, ipv4}

    assert Endpoint.address_to_string(ipv6) == "tcp://[::1]:44322"
    assert Client.parse_address(Endpoint.address_to_string(ipv6)) == {:ok, ipv6}
  end

  test "Windows named pipe endpoint addresses round-trip encoded path segments" do
    pipe = ~S(\\.\pipe\twelvgaige team\breech)
    address = {:npipe, pipe}

    assert Endpoint.address_to_string(address) == "npipe:////./pipe/twelvgaige%20team/breech"
    assert Client.parse_address(Endpoint.address_to_string(address)) == {:ok, address}
    assert Client.parse_address(pipe) == {:ok, address}
  end

  test "rejects malformed endpoint addresses" do
    assert Client.parse_address("tcp://127.0.0.1") == {:error, :invalid_ipc_address}
    assert Client.parse_address("tcp://localhost:44321") == {:error, :invalid_ipc_address}
    assert Client.parse_address("tcp://::1:44321") == {:error, :invalid_ipc_address}
    assert Client.parse_address("unix://") == {:error, :invalid_ipc_address}
    assert Client.parse_address("npipe:////./pipe") == {:error, :invalid_ipc_address}
    assert Client.parse_address("\\\\.\\pipe\\") == {:error, :invalid_ipc_address}
  end

  test "does not create atoms while decoding unknown remote errors" do
    class = "class_#{System.unique_integer([:positive, :monotonic])}"
    reason = "reason_#{System.unique_integer([:positive, :monotonic])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(class) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(reason) end

    transport = fn _path, _payload, _opts ->
      {:ok,
       Twelvgaige.Breech.IPC.Protocol.encode(%{
         "ok" => false,
         "error" => %{
           "class" => class,
           "reason" => reason,
           "message" => "malformed remote error"
         }
       })}
    end

    assert Client.status({:npipe, ~S(\\.\pipe\twelvgaige-test)}, npipe_transport: transport) ==
             {:error, reason}

    assert_raise ArgumentError, fn -> String.to_existing_atom(class) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(reason) end
  end
end
