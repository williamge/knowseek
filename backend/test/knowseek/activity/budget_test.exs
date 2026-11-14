defmodule Knowseek.Activity.BudgetTest do
  use ExUnit.Case, async: true

  alias Knowseek.Activity.Budget

  describe "level/3" do
    test "is :ok under the share" do
      assert Budget.level(89, 100, 0.9) == :ok
      assert Budget.level(0, 100, 0.9) == :ok
    end

    test "is :near from the share up to the limit" do
      assert Budget.level(90, 100, 0.9) == :near
      assert Budget.level(99, 100, 0.9) == :near
    end

    test "is :full at the limit and above" do
      assert Budget.level(100, 100, 0.9) == :full
      assert Budget.level(150, 100, 0.9) == :full
    end

    test "a limit of 0 is :full with 0 used" do
      assert Budget.level(0, 0, 0.9) == :full
    end
  end

  # A budget as `Knowseek.Activity.budget/1` builds it.
  defp budget(attrs \\ []) do
    %{
      disk: %{used: 0, limit: 100, state: Keyword.get(attrs, :disk, :ok)},
      network: %{used: 0, limit: 100, state: Keyword.get(attrs, :network, :ok)},
      free_disk: %{bytes: nil, floor: 10, low: Keyword.get(attrs, :low, false)},
      background_share: 0.9
    }
  end

  describe "hold/2" do
    test "is nil when all is well, for both kinds" do
      assert Budget.hold(:background, budget()) == nil
      assert Budget.hold(:search, budget()) == nil
    end

    test "background is held at :near and :full disk" do
      assert Budget.hold(:background, budget(disk: :near)) == :disk
      assert Budget.hold(:background, budget(disk: :full)) == :disk
    end

    test "background is held on low free disk" do
      assert Budget.hold(:background, budget(low: true)) == :free_disk
    end

    test "background is held at :near and :full network" do
      assert Budget.hold(:background, budget(network: :near)) == :network
      assert Budget.hold(:background, budget(network: :full)) == :network
    end

    test "when two apply the order is disk, free disk, network" do
      assert Budget.hold(:background, budget(disk: :near, low: true, network: :full)) == :disk
      assert Budget.hold(:background, budget(low: true, network: :full)) == :free_disk
      assert Budget.hold(:background, budget(disk: :full, network: :near)) == :disk
    end

    test "search is held only on :full, disk first" do
      assert Budget.hold(:search, budget(disk: :near, network: :near)) == nil
      assert Budget.hold(:search, budget(disk: :full)) == :disk
      assert Budget.hold(:search, budget(network: :full)) == :network
      assert Budget.hold(:search, budget(disk: :full, network: :full)) == :disk
    end

    test "search ignores free disk" do
      assert Budget.hold(:search, budget(low: true)) == nil
    end
  end
end
