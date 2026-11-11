defmodule Knowseek.Crawl.ScoreTest do
  use ExUnit.Case, async: true

  alias Knowseek.Crawl.Score

  describe "cosine/2" do
    test "is 1.0 for equal vectors" do
      assert_in_delta Score.cosine([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]), 1.0, 1.0e-9
    end

    test "is 0.0 for orthogonal vectors" do
      assert_in_delta Score.cosine([1.0, 0.0], [0.0, 1.0]), 0.0, 1.0e-9
    end

    test "is 0.0 when a vector has no length" do
      assert Score.cosine([0.0, 0.0], [1.0, 1.0]) == 0.0
      assert Score.cosine([1.0, 1.0], [0.0, 0.0]) == 0.0
    end
  end

  describe "interest/2" do
    test "is the largest cosine to any query" do
      assert_in_delta Score.interest([1.0, 0.0], [[0.0, 1.0], [1.0, 0.0], [1.0, 1.0]]),
                      1.0,
                      1.0e-9
    end

    test "is 0.0 for no queries" do
      assert Score.interest([1.0, 0.0], []) == 0.0
    end
  end

  describe "novelty/2" do
    test "is 1 - near / full, capped at full" do
      assert Score.novelty(0, 10) == 1.0
      assert_in_delta Score.novelty(3, 10), 0.7, 1.0e-9
      assert Score.novelty(10, 10) == 0.0
      assert Score.novelty(14, 10) == 0.0
    end
  end

  describe "base/3" do
    test "is interest * novelty + gap" do
      assert_in_delta Score.base(0.8, 0.5, 0.1), 0.5, 1.0e-9
    end
  end

  describe "rarity/2" do
    test "is 0.0 for a count of 1" do
      assert Score.rarity(1, [1, 1, 2]) == 0.0
    end

    test "is 0.0 for fewer than two links" do
      assert Score.rarity(3, [3]) == 0.0
      assert Score.rarity(3, []) == 0.0
    end

    test "is 0.0 when every link has the count" do
      assert_in_delta Score.rarity(2, [2, 2, 2, 2]), 0.0, 1.0e-9
    end

    test "is 1.0 when only one of the links has the count" do
      assert_in_delta Score.rarity(2, [2, 1, 1, 1]), 1.0, 1.0e-9
    end

    test "is ln(n / n_ge) / ln(n)" do
      # 4 links, 2 with a count of at least 2: ln(2) / ln(4)
      assert_in_delta Score.rarity(2, [2, 2, 1, 1]), 0.5, 1.0e-9

      # 202 links, 6 with a count of 6: ln(202 / 6) / ln(202)
      counts = List.duplicate(6, 6) ++ List.duplicate(1, 196)
      assert_in_delta Score.rarity(6, counts), 0.662, 0.001
    end
  end

  describe "shared/3" do
    test "is 0.0 for a count of 1" do
      assert Score.shared(1, 0.9, 0.1) == 0.0
    end

    test "is bonus * (count - 1) / 2 * rarity" do
      assert_in_delta Score.shared(2, 0.5, 0.1), 0.025, 1.0e-9
    end

    test "caps at two extra pages" do
      assert_in_delta Score.shared(3, 1.0, 0.1), 0.1, 1.0e-9
      assert_in_delta Score.shared(9, 1.0, 0.1), 0.1, 1.0e-9
    end
  end

  describe "text/2" do
    test "joins title and description" do
      assert Score.text("Desem", "sourdough starter") == "Desem: sourdough starter"
    end

    test "is the title alone without a description" do
      assert Score.text("Desem", nil) == "Desem"
      assert Score.text("Desem", "") == "Desem"
    end
  end
end
