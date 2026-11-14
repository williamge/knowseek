defmodule Knowseek.Entities.WikidataDownloadTest do
  # Changes the global download sink, so it is not async.
  use ExUnit.Case, async: false

  import Knowseek.Fixtures

  alias Knowseek.DownloadSink
  alias Knowseek.Entities.Wikidata

  setup do
    DownloadSink.capture()
    stub_wikidata()
  end

  test "counts the bytes of every response for the source wikidata" do
    assert {:ok, [_ | _]} = Wikidata.search("nvidia", [])

    # The search and the details call.
    assert_receive {:downloaded, "wikidata", search_bytes} when search_bytes > 0
    assert_receive {:downloaded, "wikidata", details_bytes} when details_bytes > 0
  end
end
