defmodule Knowseek.Crawl.Idle do
  @moduledoc """
  Whether the instance is idle, so that the background crawl may run (#89,
  ADR 0033): no logged search for `idle_seconds`, and the 1-minute load
  average per core under `max_load` (`Knowseek.Crawl` config). The load comes
  from `:cpu_sup` (the `os_mon` application). A load that cannot be read means
  not idle.
  """
  require Logger

  alias Knowseek.Activity

  @doc """
  Whether the instance is idle: no logged search for `idle_seconds`, and the
  1-minute load average per core under `max_load`. No search at all counts as
  quiet. Options (tests): `:now`, `:last_search_at`, `:load`.
  """
  @spec idle?(keyword()) :: boolean()
  def idle?(opts \\ []) do
    config = Application.get_env(:knowseek, Knowseek.Crawl, [])
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() end)
    last = last_search_at(opts)

    quiet?(last, now, config[:idle_seconds]) and low_load?(load(opts), config[:max_load])
  end

  @doc """
  The 1-minute load average divided by the number of schedulers online, or
  `nil` when the system does not report one.
  """
  @spec load_per_core() :: float() | nil
  def load_per_core do
    case :cpu_sup.avg1() do
      load when is_integer(load) -> load / 256 / System.schedulers_online()
      _unknown -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp last_search_at(opts) do
    case Keyword.fetch(opts, :last_search_at) do
      {:ok, at} -> at
      :error -> Activity.last_search_at()
    end
  end

  defp load(opts) do
    case Keyword.fetch(opts, :load) do
      {:ok, load} -> load
      :error -> load_per_core()
    end
  end

  defp quiet?(nil, _now, _idle_seconds), do: true
  defp quiet?(last, now, idle_seconds), do: DateTime.diff(now, last) >= idle_seconds

  defp low_load?(nil, _max_load) do
    # One warning per start: the check runs every minute.
    unless :persistent_term.get({__MODULE__, :warned}, false) do
      :persistent_term.put({__MODULE__, :warned}, true)

      Logger.warning("crawl: the system reports no load average; the crawl will not run")
    end

    false
  end

  defp low_load?(load, max_load), do: load < max_load
end
