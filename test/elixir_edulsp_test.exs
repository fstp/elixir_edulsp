defmodule ElixirEdulsp.CLI.Test do
  use ExUnit.Case
  use Patch
  doctest ElixirEdulsp.CLI

  describe "read_content/2" do
    test "Read 5 bytes" do
      Patch.expose(ElixirEdulsp.CLI, read_content: 2)
      content = "Hello, World!"
      {:ok, device} = StringIO.open(content)
      hello = private(ElixirEdulsp.CLI.read_content(device, 5))
      assert hello == "Hello"
    end
  end

  describe "read_content_length/1" do
    test "Find Content-Length header" do
      Patch.expose(ElixirEdulsp.CLI, read_content_length: 1)

      {:ok, device} =
        StringIO.open("""
        Random-Header: 123\r
        Content-Length: 17\r
        Another-Header: abc\r
        \r
        {"testing": true}
        """)

      content_length = private(ElixirEdulsp.CLI.read_content_length(device))
      assert content_length == 17
    end

    test "No Content-Length header" do
      Patch.expose(ElixirEdulsp.CLI, read_content_length: 1)

      {:ok, device} =
        StringIO.open("""
        Random-Header: 123\r
        Another-Header: abc\r
        \r
        {"testing": true}
        """)

      content_length = private(ElixirEdulsp.CLI.read_content_length(device))
      assert content_length == nil
    end
  end

  describe "read_headers/1" do
    test "Read headers until empty line" do
      Patch.expose(ElixirEdulsp.CLI, read_headers: 1)
      {:ok, device} = StringIO.open("Header1: Value1\r\nHeader2: Value2\r\n\r\n")
      headers = private(ElixirEdulsp.CLI.read_headers(device))
      assert length(headers) == 2
    end
  end
end
