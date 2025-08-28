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
          Logger.info(content_length: content_length)
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
    IO.binread(device, content_length)
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
    Logger.info("Starting new manager")
    {:ok, manager} = ElixirEdulsp.Manager.start_link(name, version, device)
    Map.put(state, :manager, manager)
  end

  defp handle_message(_device, msg, %{manager: manager} = state) do
    :gen_statem.call(manager, {:message, msg})
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
              Logger.info(recv_msg: message)
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

defmodule ElixirEdulsp.Manager do
  @behaviour :gen_statem
  require Logger

  @spec start_link(String.t(), String.t(), IO.device()) :: :gen_statem.start_ret()
  def start_link(name, version, device) do
    :gen_statem.start_link(__MODULE__, {name, version, device}, [])
  end

  def stop(pid) do
    :gen_statem.stop(pid)
  end

  @impl true
  def callback_mode(), do: :handle_event_function

  @impl true
  def init({name, version, device}) do
    state = :waiting_for_notification
    Logger.info(state: state, name: name, version: version, device: device)
    new_id = send_initialize_response(device, 1)
    data = %{name: name, version: version, device: device, id: new_id}
    {:ok, state, data}
  end

  @impl true
  def handle_event(event_type, event_data, state, data)

  def handle_event(
        {:call, _from},
        {:message, %{"method" => "initialized", "params" => params}},
        :waiting_for_notification = state,
        data
      ) do
    new_state = :ready
    Logger.info("Received initialized notification")
    Logger.info(state_change: %{from: state, to: new_state})
    Logger.info(params: params, state: new_state, data: data)
    {:next_state, new_state, data}
  end

  def handle_event(event_type, event_data, state, data) do
    Logger.info("Unhandled event")
    Logger.info(event_type: event_type, event_data: event_data, state: state, data: data)
    :keep_state_and_data
  end

  defp encode_response(body) do
    body_json = Jason.encode!(body)
    "Content-Length: #{byte_size(body_json)}\r\n\r\n#{body_json}"
  end

  defp send_response(device, body) do
    Logger.info(send_msg: body)
    response = encode_response(body)
    IO.binwrite(device, response)
  end

  defp send_initialize_response(device, id) do
    body = %{
      "capabilities" => %{
        "textDocumentSync" => 1,
        "hoverProvider" => true,
        "completionProvider" => %{"resolveProvider" => false, "triggerCharacters" => ["."]},
        "signatureHelpProvider" => %{
          "triggerCharacters" => ["(", ","],
          "retriggerCharacters" => [")"]
        },
        "definitionProvider" => true,
        "referencesProvider" => true,
        "documentHighlightProvider" => true,
        "documentSymbolProvider" => true,
        "workspaceSymbolProvider" => true,
        "codeActionProvider" => true,
        "codeLensProvider" => %{"resolveProvider" => false},
        "documentFormattingProvider" => true,
        "documentRangeFormattingProvider" => true,
        "renameProvider" => true,
        "foldingRangeProvider" => true
      },
      "serverInfo" => %{"name" => "elixir_edulsp", "version" => "0.1.0"}
    }

    send_response(device, %{"jsonrpc" => "2.0", "id" => id, "result" => body})
    id + 1
  end
end
