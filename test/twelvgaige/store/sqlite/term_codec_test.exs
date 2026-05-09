defmodule Twelvgaige.Store.SQLite.TermCodecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Twelvgaige.Store.SQLite.TermCodec

  property "round-trips JSON-like persistence terms" do
    check all(
            value <- json_value(),
            max_runs: 50
          ) do
      assert TermCodec.decode(TermCodec.encode(value)) == value
    end
  end

  test "nullable helpers preserve nil outside encoded blobs" do
    assert TermCodec.encode_nullable(nil) == nil
    assert TermCodec.decode_nullable(nil) == nil

    assert TermCodec.decode_nullable(TermCodec.encode_nullable(%{status: :complete})) == %{
             status: :complete
           }
  end

  test "preloads known structs and atoms used by safe decode" do
    assert :ok = TermCodec.preload()
  end

  defp json_value do
    leaf =
      StreamData.one_of([
        StreamData.integer(),
        StreamData.boolean(),
        StreamData.string(:printable, max_length: 32),
        StreamData.constant(nil)
      ])

    StreamData.one_of([
      leaf,
      StreamData.list_of(leaf, max_length: 5),
      StreamData.map_of(
        StreamData.string(:alphanumeric, min_length: 1, max_length: 12),
        leaf,
        max_length: 5
      ),
      StreamData.map_of(
        StreamData.string(:alphanumeric, min_length: 1, max_length: 12),
        StreamData.list_of(leaf, max_length: 5),
        max_length: 5
      )
    ])
  end
end
