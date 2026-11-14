defmodule Knowseek.DownloadTest.Sink do
  @moduledoc false

  # Runs in the process that makes the request, which is the test process.
  def send_to_caller(source, bytes), do: send(self(), {:counted, source, bytes})
end

defmodule Knowseek.DownloadTest do
  # `count/2` reads the sink from the application environment, which is global.
  # No database is used.
  use ExUnit.Case, async: false

  alias Knowseek.Download

  @stub __MODULE__

  defp response(attrs), do: struct!(Req.Response, attrs)

  defp request do
    Req.new(url: "http://download.test/", plug: {Req.Test, @stub}, retry: false)
  end

  defp stub_body(body) do
    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-test", "1")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  describe "size/1" do
    test "adds the header line (name, value and 4 bytes) and the body" do
      response = response(headers: %{"server" => ["test"]}, body: "hello")

      # "server" 6 + "test" 4 + 4 for ": " and the line break, plus 5.
      assert Download.size(response) == 6 + 4 + 4 + 5
    end

    test "counts every value of a header" do
      response = response(headers: %{"set-cookie" => ["a=1", "b=22"]}, body: "")

      assert Download.size(response) == 10 + 3 + 4 + (10 + 4 + 4)
    end

    test "a body that is not a binary counts 0" do
      response = response(headers: %{"server" => ["test"]}, body: %{"a" => 1})

      assert Download.size(response) == 6 + 4 + 4
    end
  end

  describe "measure/2" do
    test "calls the function with the size of the response" do
      stub_body("hello")
      test_pid = self()

      response = request() |> Download.measure(&send(test_pid, {:size, &1})) |> Req.get!()

      assert_received {:size, size}
      assert size == Download.size(response)
      assert size > 5
    end

    test "nil adds no step" do
      stub_body("hello")
      request = request()

      assert Download.measure(request, nil) == request
      assert Req.get!(request).body == "hello"
    end
  end

  describe "count/2" do
    setup do
      config = Application.get_env(:knowseek, Download, [])
      on_exit(fn -> Application.put_env(:knowseek, Download, config) end)
    end

    test "reports the source and the size to the sink" do
      Application.put_env(:knowseek, Download,
        sink: {Knowseek.DownloadTest.Sink, :send_to_caller}
      )

      stub_body("hello")

      response = request() |> Download.count("wikidata") |> Req.get!()

      assert_received {:counted, "wikidata", bytes}
      assert bytes == Download.size(response)
    end

    test "without a sink nothing is reported and the request is as it was" do
      Application.put_env(:knowseek, Download, sink: nil)
      stub_body("hello")
      request = request()

      assert Download.count(request, "wikidata") == request
      Req.get!(request)

      refute_received {:counted, _source, _bytes}
    end
  end
end
