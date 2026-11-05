defmodule Knowseek.RuntimePlannerTest do
  # Reads config/runtime.exs with different environment variables each time.
  use ExUnit.Case, async: false

  alias Knowseek.Discovery.Planner
  alias Knowseek.Discovery.Planner.Ollama

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @vars ~w(PLANNER_ADAPTER OLLAMA_CHAT_MODEL OLLAMA_URL OLLAMA_MODEL)

  defp restore_env({name, nil}), do: System.delete_env(name)
  defp restore_env({name, value}), do: System.put_env(name, value)

  defp put_env(env, name) do
    case Map.fetch(env, name) do
      {:ok, value} -> System.put_env(name, value)
      :error -> System.delete_env(name)
    end
  end

  # The config runtime.exs would set with `env`, in the `dev` environment (the
  # block that reads the variables runs for every environment but `test`).
  defp runtime_config(env) do
    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, &restore_env/1) end)
    Enum.each(@vars, &put_env(env, &1))

    @runtime |> Config.Reader.read!(env: :dev, target: :host) |> Keyword.fetch!(:knowseek)
  end

  defp adapter(config), do: config |> Keyword.get(Planner, []) |> Keyword.get(:adapter)
  defp ollama(config), do: Keyword.get(config, Ollama, [])

  test "nothing set leaves config.exs in effect: the pass-through planner, the default model" do
    config = runtime_config(%{})

    assert adapter(config) == nil
    assert ollama(config) == []
    assert Application.fetch_env!(:knowseek, Planner)[:adapter] == Planner.Passthrough
    assert Application.fetch_env!(:knowseek, Ollama)[:model] == "qwen2.5:3b"
  end

  test "empty or blank values are the same as unset" do
    config =
      runtime_config(%{"PLANNER_ADAPTER" => "", "OLLAMA_CHAT_MODEL" => "  ", "OLLAMA_URL" => " "})

    assert adapter(config) == nil
    assert ollama(config) == []
  end

  test "PLANNER_ADAPTER selects the planner, trimmed" do
    assert adapter(runtime_config(%{"PLANNER_ADAPTER" => "ollama"})) == Planner.Ollama
    assert adapter(runtime_config(%{"PLANNER_ADAPTER" => " ollama "})) == Planner.Ollama
    assert adapter(runtime_config(%{"PLANNER_ADAPTER" => "passthrough"})) == Planner.Passthrough
  end

  test "an unknown PLANNER_ADAPTER stops the application at start" do
    assert_raise RuntimeError, ~r/unknown PLANNER_ADAPTER "claude"/, fn ->
      runtime_config(%{"PLANNER_ADAPTER" => "claude"})
    end
  end

  test "OLLAMA_CHAT_MODEL sets the model, and OLLAMA_URL is shared with the embeddings" do
    config =
      runtime_config(%{
        "OLLAMA_CHAT_MODEL" => " llama3.2:3b ",
        "OLLAMA_URL" => "http://gpu:11434"
      })

    assert ollama(config) |> Enum.sort() == [base_url: "http://gpu:11434", model: "llama3.2:3b"]
    assert config[Knowseek.Embeddings.Ollama][:base_url] == "http://gpu:11434"
    # The embedding model is a different variable.
    refute Keyword.has_key?(config[Knowseek.Embeddings.Ollama], :model)
  end
end
