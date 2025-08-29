defmodule ElixirEdulsp do
  use Application

  def start(_type, _args) do
    children = [
      %{id: EventManager, start: {:gen_event, :start_link, [{:local, :event_manager}]}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
