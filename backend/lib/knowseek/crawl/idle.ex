defmodule Knowseek.Crawl.Idle do
  @moduledoc """
  Whether the instance is idle, so that the background crawl may run (#89,
  ADR 0033): no logged search for `idle_seconds`, and the CPU busy under
  `max_cpu_percent` (`Knowseek.Crawl` config).

  The busy share comes from `:cpu_sup.util/0` (the `os_mon` application): the
  percentage of CPU time spent busy since the previous call. `Crawl.Scheduler`
  asks once a minute, so it is the share over the last minute. `cpu_sup` keeps
  that previous sample per calling process, so `idle?/1` is meant to be called
  from one process (the scheduler); the first call of a process has no
  previous sample and is **not idle**. A busy share that cannot be read is
  not idle either, and is logged once.

  The load average is not used: on macOS it counts threads that wait for the
  disk or for swap, so it stays far above the number of cores on a machine
  whose CPU is half idle.
  """
  require Logger

  alias Knowseek.Activity

  @doc """
  Whether the instance is idle: no logged search for `idle_seconds`, and the
  CPU busy share since the previous call under `max_cpu_percent`. No search at
  all counts as quiet. The busy share is read on every call, also when a
  search was logged recently, so that the next call measures the last interval
  only. Options (tests): `:now`, `:last_search_at`, and `:cpu` (a percentage,
  `:first` for a first call, `nil` for an unreadable one).
  """
  @spec idle?(keyword()) :: boolean()
  def idle?(opts \\ []) do
    config = Application.get_env(:knowseek, Knowseek.Crawl, [])
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() end)
    cpu = cpu(opts)

    quiet?(last_search_at(opts), now, config[:idle_seconds]) and
      calm?(cpu, config[:max_cpu_percent])
  end

  @doc """
  The CPU busy share (0.0 to 100.0) since this process's previous call,
  `:first` for the process's first call (which only sets the baseline), or
  `nil` when the system does not report one.
  """
  @spec cpu_percent() :: float() | :first | nil
  def cpu_percent do
    first? = Process.put({__MODULE__, :sampled}, true) != true

    case :cpu_sup.util() do
      _util when first? -> :first
      util when is_number(util) -> util / 1
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

  defp cpu(opts) do
    case Keyword.fetch(opts, :cpu) do
      {:ok, cpu} -> cpu
      :error -> cpu_percent()
    end
  end

  defp quiet?(nil, _now, _idle_seconds), do: true
  defp quiet?(last, now, idle_seconds), do: DateTime.diff(now, last) >= idle_seconds

  defp calm?(:first, _max), do: false

  defp calm?(nil, _max) do
    # One warning per start: the check runs every minute.
    unless :persistent_term.get({__MODULE__, :warned}, false) do
      :persistent_term.put({__MODULE__, :warned}, true)

      Logger.warning("crawl: the system reports no CPU utilisation; the crawl will not run")
    end

    false
  end

  defp calm?(cpu, max), do: cpu < max
end
