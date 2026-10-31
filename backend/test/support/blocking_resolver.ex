defmodule Knowseek.Entities.BlockingResolver do
  @moduledoc """
  A `Knowseek.Entities.Resolver` for tests that count concurrent resolutions:
  `search/2` sends `{:resolving, pid, text}` to the test process registered
  with `register/1`, waits for `:release` sent to `pid`, and finds nothing.
  """
  @behaviour Knowseek.Entities.Resolver

  @doc "Sends the `{:resolving, ...}` messages to the calling process."
  def register(test_pid \\ self()), do: Application.put_env(:knowseek, __MODULE__, test_pid)

  @impl true
  def search(text, _opts) do
    send(Application.fetch_env!(:knowseek, __MODULE__), {:resolving, self(), text})

    receive do
      :release -> {:ok, []}
    end
  end
end
