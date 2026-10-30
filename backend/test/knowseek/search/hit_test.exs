defmodule Knowseek.Search.HitTest do
  use ExUnit.Case, async: true

  alias Knowseek.Search.Hit

  describe "relevant?/2" do
    test "is true for a keyword match, whatever the similarity" do
      assert Hit.relevant?(%Hit{keyword_rank: 1, similarity: 0.0}, 0.5)
      assert Hit.relevant?(%Hit{keyword_rank: 7, similarity: nil}, 0.5)
    end

    test "is true for a similarity at or above the minimum" do
      assert Hit.relevant?(%Hit{keyword_rank: nil, similarity: 0.5}, 0.5)
      assert Hit.relevant?(%Hit{keyword_rank: nil, similarity: 0.9}, 0.5)
    end

    test "is false for a similarity below the minimum" do
      refute Hit.relevant?(%Hit{keyword_rank: nil, similarity: 0.49}, 0.5)
    end

    test "is false without a keyword match or a similarity" do
      refute Hit.relevant?(%Hit{keyword_rank: nil, similarity: nil}, 0.5)
    end

    test "accepts a plain map" do
      assert Hit.relevant?(%{keyword_rank: nil, similarity: 0.8}, 0.5)
    end
  end
end
