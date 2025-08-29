alias ElixirEdulsp.CLI.Test.EventListener

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

  describe "Functional tests" do
    @tag timeout: 5000
    test "Run testcase from file" do
      Patch.expose(ElixirEdulsp.CLI, read_json: 2)
      EventListener.start(self())
      {:ok, device} = File.read!("test/testcase.txt") |> StringIO.open()
      private(ElixirEdulsp.CLI.read_json(device, %{}))

      # Assert that we reach the ready state
      # (Receive "initialize" and "initialized" notification)
      assert_receive [state_change: %{to: :ready, from: :waiting_for_notification}]
    end
  end
end

defmodule ElixirEdulsp.CLI.Test.EventListener do
  @behaviour :gen_event
  require Logger

  def start(pid) do
    :gen_event.add_handler(:event_manager, EventListener, %{pid: pid})
  end

  @impl true
  def init(state) do
    Logger.info("Event listener started")
    {:ok, state}
  end

  @impl true
  def handle_event(event, state) do
    Process.send(state.pid, event, [])
    {:ok, state}
  end

  @impl true
  def handle_call(request, state) do
    Process.send(state.pid, request, [])
    {:ok, :ok, state}
  end
end
