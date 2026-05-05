defmodule Twelvgaige.SecurityTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Security

  test "secure_equal? accepts only equal-size identical binaries" do
    assert Security.secure_equal?("same", "same")

    refute Security.secure_equal?("same", "diff")
    refute Security.secure_equal?("same", "same-but-longer")
    refute Security.secure_equal?("same", :same)
    refute Security.secure_equal?(nil, nil)
  end
end
