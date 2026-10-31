defmodule KnowseekWeb.FallbackControllerTest do
  use KnowseekWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias KnowseekWeb.FallbackController

  test "an embedding provider error is a 503 with a JSON body", %{conn: conn} do
    log =
      capture_log(fn ->
        conn = FallbackController.call(conn, {:error, {:ollama, %{reason: :econnrefused}}})

        assert json_response(conn, 503) == %{
                 "errors" => %{"detail" => "Embedding provider unavailable (ollama)"}
               }
      end)

    assert log =~ "embedding provider unavailable"
  end
end
