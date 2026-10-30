defmodule Knowseek.Documents.ChunkerTest do
  use ExUnit.Case, async: true

  alias Knowseek.Documents.Chunker

  test "returns no chunks for blank text" do
    assert Chunker.chunk("   \n\n  ") == []
  end

  test "packs short paragraphs into one chunk" do
    assert Chunker.chunk("First para.\n\nSecond para.") == ["First para.\n\nSecond para."]
  end

  test "starts a new chunk when the next paragraph does not fit" do
    text = String.duplicate("a", 30) <> "\n\n" <> String.duplicate("b", 30)

    assert Chunker.chunk(text, max_chars: 40) == [
             String.duplicate("a", 30),
             String.duplicate("b", 30)
           ]
  end

  test "splits a long paragraph on word boundaries" do
    text = Enum.map_join(1..20, " ", fn _ -> "word" end)
    chunks = Chunker.chunk(text, max_chars: 25)

    assert length(chunks) > 1
    assert Enum.all?(chunks, &(String.length(&1) <= 25))
    assert Enum.join(chunks, " ") == text
  end
end
