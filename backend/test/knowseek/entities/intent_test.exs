defmodule Knowseek.Entities.IntentTest do
  use ExUnit.Case, async: true

  alias Knowseek.Entities.Intent

  doctest Knowseek.Entities.Intent

  describe "split/1" do
    test "splits `weather in <place>`" do
      assert Intent.split("weather in tokyo") == {:weather, "tokyo"}
      assert Intent.split("weather in New York") == {:weather, "New York"}
    end

    test "splits `<place> weather`" do
      assert Intent.split("tokyo weather") == {:weather, "tokyo"}
      assert Intent.split("new york weather") == {:weather, "new york"}
    end

    test "ignores case and extra spaces, and keeps the case of the place" do
      assert Intent.split("  Weather   IN   Tokyo ") == {:weather, "Tokyo"}
      assert Intent.split("Tokyo WEATHER") == {:weather, "Tokyo"}
    end

    test "anything else has no intent and is resolved whole" do
      assert Intent.split("knicks") == {nil, "knicks"}
      assert Intent.split("  new   york  knicks ") == {nil, "new york knicks"}
      assert Intent.split("weather forecast tokyo") == {nil, "weather forecast tokyo"}
    end

    test "a bare `weather` has no place, so no intent" do
      assert Intent.split("weather") == {nil, "weather"}
      assert Intent.split("weather in") == {nil, "weather in"}
      assert Intent.split("") == {nil, ""}
    end
  end
end
