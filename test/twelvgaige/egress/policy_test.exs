defmodule Twelvgaige.Egress.PolicyTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Egress.Policy

  test "pins public DNS and rejects private resolution and redirect targets" do
    public = fn _host -> {:ok, [{104, 18, 33, 45}]} end
    private = fn _host -> {:ok, [{127, 0, 0, 1}]} end

    assert {:ok, %{pinned_address: {104, 18, 33, 45}}} =
             Policy.authorize_uri("https://api.example.com/v1", ["api.example.com"],
               resolver: public
             )

    assert {:error, :egress_private_address_denied} =
             Policy.authorize_uri("https://api.example.com/v1", ["api.example.com"],
               resolver: private
             )

    assert {:error, :egress_host_denied} =
             Policy.authorize_redirect(
               URI.parse("https://api.example.com/v1"),
               "https://metadata.internal/token",
               ["api.example.com"],
               resolver: public
             )
  end

  test "normalizes hostnames, rejects embedded credentials, and blocks mapped private IPv4" do
    public = fn _host -> {:ok, [{104, 18, 33, 45}]} end

    assert {:ok, %{host: "api.example.com"}} =
             Policy.authorize_uri("https://API.EXAMPLE.COM./v1", ["api.example.com"],
               resolver: public
             )

    assert {:error, :egress_userinfo_denied} =
             Policy.authorize_uri("https://name:secret@api.example.com/v1", ["api.example.com"],
               resolver: public
             )

    mapped_private = fn _host -> {:ok, [{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}]} end

    assert {:error, :egress_private_address_denied} =
             Policy.authorize_uri("https://api.example.com/v1", ["api.example.com"],
               resolver: mapped_private
             )
  end
end
