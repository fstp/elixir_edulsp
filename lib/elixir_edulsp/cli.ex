alias ElixirEdulsp.StateManager

defmodule ElixirEdulsp.CLI do
  require Logger

  @spec read_content_length(IO.device()) :: integer() | nil
  defp read_content_length(device) do
    pattern = ~r/Content-Length: (\d+)/

    IO.stream(device, :line)
    |> Enum.find_value(fn line ->
      case Regex.run(pattern, line) do
        [_match, digits] ->
          content_length = String.to_integer(digits)
          # Logger.info(content_length: content_length)
          content_length

        nil ->
          Logger.warning(unknown_input: line)
          nil
      end
    end)
  end

  @spec read_headers(IO.device()) :: [String]
  defp read_headers(device) do
    IO.stream(device, :line)
    |> Enum.take_while(fn line -> String.trim(line) != "" end)
  end

  @spec read_content(IO.device(), integer()) :: iodata() | IO.nodata()
  defp read_content(device, content_length) do
    message = IO.binread(device, content_length)
    message
  end

  @spec handle_message(IO.device(), map(), map()) :: map()
  defp handle_message(
         _device,
         %{"method" => "initialize"},
         %{manager: _} = state
       ) do
    # TODO: Restart manager here?
    Logger.error("Manager already exists")
    state
  end

  defp handle_message(
         device,
         %{
           "method" => "initialize",
           "params" => %{"clientInfo" => %{"name" => name, "version" => version}}
         },
         state
       ) do
    {:ok, manager} = StateManager.start_link(name, version, device)
    Map.put(state, :manager, manager)
  end

  defp handle_message(_device, msg, %{manager: manager} = state) do
    StateManager.receive_msg(manager, msg)
    state
  end

  defp handle_message(_device, msg, state) do
    Logger.error(error: "Unexpected message", msg: msg, state: state)
    state
  end

  @spec read_json(IO.device(), map()) :: no_return()
  defp read_json(device, state) do
    # Content-Length: 17\r\n\r\n{"testing": true}
    case read_content_length(device) do
      nil ->
        :done

      content_length ->
        read_headers(device)

        state =
          case Jason.decode(read_content(device, content_length)) do
            {:ok, message} ->
              handle_message(device, message, state)

            {:error, reason} ->
              Logger.error(decode_error: reason)
              state
          end

        read_json(device, state)
    end
  end

  def main(args) do
    {opts, _remaining_args, _invalid} = OptionParser.parse(args, strict: [logdir: :string])
    Logger.info(opts: opts)
    log_dir = Keyword.get(opts, :logdir)

    if log_dir do
      Logger.info("Setting log directory to: #{log_dir}")

      Logger.configure_backend({LoggerFileBackend, :file_log},
        path: Path.join(log_dir, "elixir_edulsp.log")
      )
    end

    device = :stdio
    read_json(device, %{})
  end
end

defmodule ElixirEdulsp.StateManager do
  @behaviour :gen_statem
  require Logger

  @spec start_link(String.t(), String.t(), IO.device()) :: :gen_statem.start_ret()
  def start_link(name, version, device) do
    :gen_statem.start_link(__MODULE__, {name, version, device}, [])
  end

  def stop(pid) do
    :gen_statem.stop(pid)
  end

  def receive_msg(pid, msg) do
    :gen_statem.call(pid, {:message, msg})
  end

  @impl true
  def callback_mode(), do: [:handle_event_function, :state_enter]

  @impl true
  def init({name, version, device}) do
    data = %{name: name, version: version, device: device}
    Logger.info("Received initialize request")
    Logger.info(data: data)
    send_initialize_response(device)
    {:ok, :waiting_for_notification, data}
  end

  @impl true
  def handle_event(
        {:call, from},
        {:message, %{"method" => "initialized", "params" => params}},
        :waiting_for_notification,
        data
      ) do
    Logger.info("Received initialized notification")
    Logger.info(params: params, data: data)
    {:next_state, :ready, data, {:reply, from, :ok}}
  end

  @impl true
  def handle_event(
        {:call, from},
        {:message,
         %{
           "method" => "textDocument/didOpen",
           "params" => %{"textDocument" => %{"uri" => "file://"}}
         }},
        _state,
        _data
      ) do
    Logger.info("Hover window opened")
    {:keep_state_and_data, {:reply, from, :ok}}
  end

  @impl true
  def handle_event(
        {:call, from},
        {:message, %{"method" => "textDocument/didOpen", "params" => params}},
        _state,
        data
      ) do
    %{"textDocument" => %{"text" => text}} = params
    lines = String.split(text, "\n")
    Logger.info("Received didOpen notification")
    {:next_state, :document, Map.put(data, :lines, lines), {:reply, from, :ok}}
  end

  @impl true
  def handle_event(
        {:call, from},
        {:message, %{"method" => "textDocument/didChange", "params" => params}},
        :document,
        %{lines: lines} = data
      ) do
    format_pos = fn change, pos ->
      range = get_in(change, ["range", pos])
      "(#{range["line"]}, #{range["character"]})"
    end

    params["contentChanges"]
    |> Enum.each(fn change ->
      Logger.info(
        "Change: #{format_pos.(change, "start")} -> #{format_pos.(change, "end")}\n#{change["text"]}"
      )
    end)

    updated_lines =
      params["contentChanges"]
      |> Enum.reduce(lines, fn change, acc ->
        Logger.info(change: change)
        update_document(acc, change["range"], change["text"])
      end)

    Logger.info("Document:\n#{Enum.join(updated_lines, "\n")}")

    {:next_state, :document, %{data | lines: updated_lines}, {:reply, from, :ok}}
  end

  @impl true
  def handle_event(
        {:call, from},
        {:message, %{"method" => "textDocument/didSave"}},
        :document,
        _data
      ) do
    Logger.info("Received didSave notification")
    {:keep_state_and_data, {:reply, from, :ok}}
  end

  @impl true
  def handle_event(
        {:call, from},
        {:message, %{"id" => id, "method" => "textDocument/hover", "params" => params}},
        :document,
        %{device: device}
      ) do
    Logger.info("Received hover request")

    %{"position" => %{"character" => char, "line" => line}} = params

    # Neovim line/columns are 1-based, LSP is 0-based
    hover_text = """
    Line: #{line + 1}
    Column: #{char + 1}
    """

    send_hover_response(device, id, hover_text)
    {:keep_state_and_data, {:reply, from, :ok}}
  end

  @impl true
  # Handles the hover window being closed in Neovim.
  # TODO: detecting the hover window by checking for a specific URI.
  def handle_event(
        {:call, from},
        {:message,
         %{
           "method" => "textDocument/didClose",
           "params" => %{"textDocument" => %{"uri" => "file://"}}
         }},
        _state,
        _data
      ) do
    Logger.info("Hover window closed")
    {:keep_state_and_data, {:reply, from, :ok}}
  end

  @impl true
  def handle_event(
        {:call, from},
        {:message, %{"method" => "textDocument/didClose"}},
        _state,
        _data
      ) do
    Logger.info("Received didClose notification")
    {:keep_state_and_data, {:reply, from, :ok}}
  end

  @impl true
  # Handles a code action request that was explicitly triggered by the user or an extension.
  # This clause specifically processes textDocument/codeAction requests with triggerKind=1,
  # which indicates an explicit user-initiated code action request rather than an automatic one.
  def handle_event(
        {:call, from},
        {:message,
         %{
           "id" => id,
           "method" => "textDocument/codeAction",
           "params" => %{
             "context" => %{"diagnostics" => diag, "triggerKind" => 1},
             "range" => range
           }
         }},
        :document,
        %{device: device}
      ) do
    Logger.info("Received codeAction request (explicit trigger)")
    Logger.info(diagnostics: diag)
    Logger.info(range: range)
    send_code_action_response(device, id, "Change the word to 'ElixirEdulsp'")
    {:keep_state_and_data, {:reply, from, :ok}}
  end

  @impl true
  def handle_event(:enter, old_state, new_state, _data) do
    Logger.info("#{old_state} -> #{new_state}")
    :gen_event.notify(:event_manager, state_change: %{from: old_state, to: new_state})
    :keep_state_and_data
  end

  @impl true
  def handle_event({:call, from}, event_data, state, data) do
    Logger.error(
      error: "Unhandled event",
      event_data: event_data,
      state: state,
      data: data
    )

    {:keep_state_and_data, {:reply, from, :ok}}
  end

  defp send_response(device, id, result) do
    msg = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    Logger.info(send_message: msg)
    json = Jason.encode!(msg)
    response = "Content-Length: #{byte_size(json)}\r\n\r\n#{json}"
    IO.binwrite(device, response)
  end

  defp send_hover_response(device, id, hover_text) do
    Logger.info("Sending hover response")
    send_response(device, id, %{"contents" => hover_text})
  end

  defp send_code_action_response(device, id, title) do
    Logger.info("Sending codeAction response")
    send_response(device, id, [%{"title" => title, "kind" => "quickfix"}])
  end

  defp send_initialize_response(device) do
    contents = %{
      "capabilities" => %{
        "textDocumentSync" => 2,
        "notebookDocumentSync" => "notebook",
        "hoverProvider" => true,
        "codeActionProvider" => true
      },
      "serverInfo" => %{"name" => "elixir_edulsp", "version" => "0.1.0"}
    }

    Logger.info("Sending initialize response")
    send_response(device, 1, contents)
  end

  def update_document(lines, %{"end" => end_, "start" => start}, new_text) do
    # Convert to 0-indexed
    line_index = start["line"]
    line = Enum.at(lines, line_index)

    Logger.info(line: line)

    Logger.info(
      "Updating line #{line_index + 1} (#{start["character"]}..#{end_["character"]}) with '#{new_text}'"
    )

    # Update the line (assuming character positions are 0-indexed)
    pre = String.slice(line, 0, start["character"])
    post = String.slice(line, end_["character"]..-1)
    Logger.info(pre: pre, new_test: new_text, post: post)
    updated_line = pre <> new_text <> post

    List.replace_at(lines, line_index, updated_line)
  end
end
