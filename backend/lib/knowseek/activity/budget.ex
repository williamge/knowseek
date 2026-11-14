defmodule Knowseek.Activity.Budget do
  @moduledoc "The budget rules (#90, ADR 0034), without any reading: levels and holds. `Knowseek.Activity.budget/1` makes the readings."

  @doc "`:full` when `used` reached `limit`, `:near` when it reached `share` of it, else `:ok`. A limit of 0 is always `:full`."
  @spec level(non_neg_integer(), non_neg_integer(), float()) :: :ok | :near | :full
  def level(used, limit, share) do
    cond do
      used >= limit -> :full
      used >= share * limit -> :near
      true -> :ok
    end
  end

  @doc """
  Why work of this kind must not start, or `nil`. Background: disk at `:near`
  or `:full`, then free disk low (or unreadable), then network at `:near` or
  `:full`. Search: disk `:full`, then network `:full`.
  """
  @spec hold(:background | :search, Knowseek.Activity.budget()) :: Knowseek.Activity.hold() | nil
  def hold(:background, budget) do
    cond do
      budget.disk.state in [:near, :full] -> :disk
      budget.free_disk.low -> :free_disk
      budget.network.state in [:near, :full] -> :network
      true -> nil
    end
  end

  def hold(:search, budget) do
    cond do
      budget.disk.state == :full -> :disk
      budget.network.state == :full -> :network
      true -> nil
    end
  end
end
