defmodule Knowseek.DownloadSink do
  @moduledoc """
  A `Knowseek.Download` sink for tests (#90): sends `{:downloaded, source, bytes}`
  to the test that called `capture/0`.

  The clients that run in supervised cache tasks call the sink from other
  processes, so the pid lives in the application environment (`:download_sink_pid`)
  and the test must not be async (the environment is global).
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "The sink: sends `{:downloaded, source, bytes}` to the capturing test."
  @spec count(String.t(), non_neg_integer()) :: :ok
  def count(source, bytes) do
    :knowseek |> Application.get_env(:download_sink_pid) |> send({:downloaded, source, bytes})
    :ok
  end

  @doc """
  Makes `Knowseek.Download` report to the calling test, and restores the
  configuration when the test ends. Call it from `setup` or a test.
  """
  @spec capture() :: :ok
  def capture do
    original = Application.fetch_env!(:knowseek, Knowseek.Download)

    on_exit(fn ->
      Application.put_env(:knowseek, Knowseek.Download, original)
      Application.delete_env(:knowseek, :download_sink_pid)
    end)

    Application.put_env(:knowseek, :download_sink_pid, self())
    Application.put_env(:knowseek, Knowseek.Download, sink: {__MODULE__, :count})
  end
end
