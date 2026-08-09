defmodule Twelvgaige.Egress.Policy do
  @moduledoc "SSRF-resistant destination, DNS, and redirect validation for broker-only egress."

  @spec authorize_uri(URI.t() | String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def authorize_uri(uri, allowed_hosts, opts \\ []) do
    uri = if is_binary(uri), do: URI.parse(uri), else: uri
    uri = normalize_uri(uri)

    with :ok <- validate_scheme(uri.scheme),
         :ok <- validate_userinfo(uri.userinfo),
         :ok <- validate_host(uri.host, allowed_hosts),
         {:ok, addresses} <- resolve(uri.host, opts),
         :ok <- validate_addresses(addresses) do
      {:ok,
       %{uri: uri, host: uri.host, addresses: addresses, pinned_address: List.first(addresses)}}
    end
  end

  def authorize_redirect(current, location, allowed_hosts, opts \\ []) do
    target = current |> URI.merge(location) |> to_string()
    authorize_uri(target, allowed_hosts, opts)
  end

  defp validate_scheme(scheme) when scheme in ["https", "http"], do: :ok
  defp validate_scheme(_scheme), do: {:error, :egress_scheme_denied}

  defp validate_userinfo(nil), do: :ok
  defp validate_userinfo(_userinfo), do: {:error, :egress_userinfo_denied}

  defp validate_host(nil, _allowed), do: {:error, :egress_host_required}

  defp validate_host(host, allowed) do
    host = normalize_host(host)

    if Enum.any?(allowed, &host_allowed?(host, normalize_host(&1))),
      do: :ok,
      else: {:error, :egress_host_denied}
  end

  defp host_allowed?(host, "*." <> suffix),
    do: String.ends_with?(host, "." <> suffix) and host != suffix

  defp host_allowed?(host, expected), do: host == expected

  defp resolve(host, opts) do
    resolver = Keyword.get(opts, :resolver, &resolve_public_families/1)

    case resolver.(host) do
      {:ok, addresses} when addresses != [] -> {:ok, addresses}
      {:error, reason} -> {:error, {:egress_dns_failed, reason}}
      _other -> {:error, :egress_dns_empty}
    end
  end

  defp resolve_public_families(host) do
    charlist = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(charlist, family) do
          {:ok, values} -> values
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    if addresses == [], do: {:error, :nxdomain}, else: {:ok, addresses}
  end

  defp validate_addresses(addresses) do
    if Enum.all?(addresses, &public_address?/1),
      do: :ok,
      else: {:error, :egress_private_address_denied}
  end

  defp public_address?({a, b, _c, _d}) do
    cond do
      a == 10 -> false
      a == 127 -> false
      a == 0 -> false
      a == 100 and b in 64..127 -> false
      a == 169 and b == 254 -> false
      a == 172 and b in 16..31 -> false
      a == 192 and b == 168 -> false
      a == 198 and b in 18..19 -> false
      a >= 224 -> false
      true -> true
    end
  end

  defp public_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp public_address?({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do:
      public_address?(
        {Bitwise.bsr(a, 8), Bitwise.band(a, 255), Bitwise.bsr(b, 8), Bitwise.band(b, 255)}
      )

  defp public_address?({first, _b, _c, _d, _e, _f, _g, _h}) when first in 0xFC00..0xFDFF,
    do: false

  defp public_address?({0xFE80, _b, _c, _d, _e, _f, _g, _h}), do: false
  defp public_address?({_a, _b, _c, _d, _e, _f, _g, _h}), do: true
  defp public_address?(_address), do: false

  defp normalize_uri(%URI{} = uri), do: %{uri | host: normalize_host(uri.host)}

  defp normalize_host(nil), do: nil

  defp normalize_host(host) do
    host
    |> String.downcase()
    |> String.trim_trailing(".")
  end
end
