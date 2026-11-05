defmodule Knowseek.Discovery.Playground do
  @moduledoc """
  The planner playground (ADR 0025): lets a developer try local chat models as
  query planners and see what each plan finds. **Dev only**: the routes that
  use it (`KnowseekWeb.PlannerPlaygroundController`) exist only when
  `:dev_routes` is true.

  It breaks AGENTS.md rule 6 on purpose: it calls Ollama in the request path.
  That is acceptable only because the routes are dev-only, bound to the
  loopback interface by `config/dev.exs`, and not part of a release's routes.
  It is read-only: nothing is ingested, `Knowseek.Documents` and the database
  are never touched, and no model is pulled (a chat call to a model that is not
  installed fails with a 404, it does not download it).

    * `models/0` - the chat models Ollama has installed (embedding-only models
      such as `bge-m3` are left out), the configured one, and the models
      loaded in memory now.
    * `preview/3` - for each model, one after another (never in parallel:
      RAM), plans the query with `Knowseek.Discovery.Planner.Ollama` and that
      model (a per-call option, no global state), times the call, and, with
      `source: true`, runs Wikipedia's search for the query as typed and for
      each planned query. It returns the titles that the top 3 results of each
      search have, and the titles that only planned queries found.

  The search is the first step of `Knowseek.Discovery.Sources.Wikipedia`
  (`search_pages/1`), the same call discovery makes. It does not fetch page
  text, so a title can be a disambiguation page that discovery would skip.

  Configuration (`config :knowseek, Knowseek.Discovery.Playground`):

    * `:planner` - the planner module (`Knowseek.Discovery.Planner.Ollama`);
      tests use a fake one
    * `:model_timeout` - milliseconds one model may take (30 s), loading
      included. A model that takes longer is reported as `"timeout"`.
    * `:keep_alive` - how long Ollama keeps a model after a playground call
      (`"1m"`, against `"5m"` for the real planner). It only matters when the
      unload below fails.

  After each model has answered (or timed out), the playground unloads **that
  chat model** (a chat request with `keep_alive: 0`), so that memory is back to
  the baseline before the next model loads. It never unloads an embedding
  model such as `bge-m3` (the dev stack needs it): only a model that
  `/api/tags` lists as a chat model is unloaded. The cost is that every
  playground call includes the load time of its model.
  """
  alias Knowseek.Discovery.Planner
  alias Knowseek.Discovery.Planner.Ollama
  alias Knowseek.Discovery.Sources.Wikipedia

  @max_models 4
  @max_query_length 500
  @top 3

  # Models with these families only embed. Used when Ollama does not list the
  # model's capabilities (older versions); newer ones do.
  @embedding_families ~w(bert nomic-bert nomic-bert-moe xlm-roberta)

  @defaults [planner: Ollama, model_timeout: 30_000, keep_alive: "1m"]

  @type model :: %{
          name: String.t(),
          size_bytes: non_neg_integer(),
          parameter_size: String.t() | nil,
          default: boolean(),
          loaded: boolean()
        }

  @doc "The most models one `preview/3` call runs."
  @spec max_models() :: pos_integer()
  def max_models, do: @max_models

  @doc "The longest query `preview/3` accepts, in characters."
  @spec max_query_length() :: pos_integer()
  def max_query_length, do: @max_query_length

  @doc "The model that `Planner.Ollama` uses when the playground is not involved."
  @spec default_model() :: String.t()
  def default_model, do: Ollama.config()[:model]

  @doc """
  The installed chat models, smallest first, and the ones loaded now. `warning`
  is set when more than one chat model is loaded.
  """
  @spec models() ::
          {:ok,
           %{
             models: [model()],
             default: String.t(),
             loaded: [String.t()],
             warning: String.t() | nil
           }}
          | {:error, String.t()}
  def models do
    with {:ok, tags} <- ollama_get("/api/tags") do
      default = default_model()
      installed = for %{"name" => _} = model <- Map.get(tags, "models", []), do: model
      chat = Enum.reject(installed, &embedding?/1)
      chat_names = Enum.map(chat, & &1["name"])
      loaded = Enum.filter(loaded_names(), &(&1 in chat_names))

      models =
        chat
        |> Enum.map(&model(&1, default, loaded))
        |> Enum.sort_by(&{&1.size_bytes, &1.name})

      {:ok, %{models: models, default: default, loaded: loaded, warning: loaded_warning(loaded)}}
    end
  end

  @doc """
  Plans `query` with each of `models`, in order, one at a time. Options:
  `:source` (default `true`) also searches Wikipedia. Never raises for a model
  that fails: its entry has the `status` and `detail`.

  A result per model:

    * `status` - `"ok"`, `"passthrough"`, `"fallback"` (the planner failed:
      only the query as typed is used; `detail` is the reason), `"timeout"` or
      `"error"` (the call did not finish)
    * `queries` - the queries searched, the one as typed first
    * `plan_ms` - milliseconds of the planner call; `warm` says whether the
      model was already loaded (`nil` when that is unknown); `unloaded` says
      whether the playground unloaded the model afterwards
    * `source` - `nil` without `:source`; else `literal` (titles of the query as typed),
      `searches` (title lists of the planned queries), `only_planned`, `wiki_ms`
  """
  @spec preview(String.t(), [String.t()], keyword()) :: map()
  def preview(query, models, opts \\ []) when is_binary(query) and is_list(models) do
    search? = Keyword.get(opts, :source, true)
    literal = if search?, do: search(query)

    %{
      query: query,
      literal: literal && Map.take(literal, [:titles, :error, :ms]),
      warning: models_warning(models),
      results: Enum.map(models, &run_model(&1, query, literal))
    }
  end

  defp run_model(model, query, literal) do
    warm = warm?(model)
    started = now()
    outcome = plan(model, query)
    plan_ms = elapsed_ms(started)
    unloaded = unload(model)

    {status, detail, queries} =
      case outcome do
        {:ok, %{status: :ok, queries: queries}} ->
          {"ok", nil, queries}

        {:ok, %{status: :passthrough, queries: queries}} ->
          {"passthrough", nil, queries}

        {:ok, %{status: {:fallback, reason}, queries: queries}} ->
          {"fallback", describe(reason), queries}

        {:error, :timeout} ->
          {"timeout", "no answer within #{timeout_seconds()} s", [query]}

        {:error, reason} ->
          {"error", describe(reason), [query]}
      end

    [_original | planned] = queries

    %{
      model: model,
      status: status,
      detail: detail,
      warm: warm,
      unloaded: unloaded,
      plan_ms: plan_ms,
      queries: queries,
      source: literal && source_result(literal, planned)
    }
  end

  # The planner runs in a task so that a model that hangs is cut off. The
  # planner never raises (`Planner.resolve/2` rescues), but the task is
  # linked, so the exit is caught anyway.
  defp plan(model, query) do
    timeout = config(:model_timeout)

    # The planner's own receive timeout is a second shorter, so that its
    # message ("timed out") arrives before the task is cut off.
    planner_opts = [
      planner: config(:planner),
      model: model,
      timeout: max(timeout - 1_000, 1_000),
      keep_alive: config(:keep_alive)
    ]

    task = Task.async(fn -> Planner.resolve(query, planner_opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  defp source_result(literal, planned) do
    started = now()

    searches =
      Enum.map(planned, fn planned_query ->
        result = search(planned_query)
        %{query: planned_query, titles: result.titles, error: result.error}
      end)

    found = MapSet.new(literal.titles)

    only_planned =
      searches
      |> Enum.flat_map(& &1.titles)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(found, &1))

    %{
      literal: %{titles: literal.titles, error: literal.error},
      searches: searches,
      only_planned: only_planned,
      wiki_ms: elapsed_ms(started)
    }
  end

  defp search(query) do
    started = now()

    case Wikipedia.search_pages(query) do
      {:ok, pages} ->
        titles = pages |> Enum.take(@top) |> Enum.map(&(&1.title || "page #{&1.pageid}"))
        %{titles: titles, error: nil, ms: elapsed_ms(started)}

      {:error, reason} ->
        %{titles: [], error: describe(reason), ms: elapsed_ms(started)}
    end
  end

  defp models_warning(models) when length(models) > 1 do
    "#{length(models)} models run one after another. Ollama keeps each one in memory for a " <>
      "minute after its call, so several large models can fill the RAM of a 16 GB machine " <>
      "and make search (embeddings) slow or fail."
  end

  defp models_warning(_models), do: nil

  defp loaded_warning([_one, _two | _rest] = loaded) do
    "#{length(loaded)} chat models are loaded now (#{Enum.join(loaded, ", ")}). Free the memory " <>
      "with `ollama stop <model>`; do not stop bge-m3, search needs it."
  end

  defp loaded_warning(_loaded), do: nil

  defp model(tag, default, loaded) do
    %{
      name: tag["name"],
      size_bytes: tag["size"] || 0,
      parameter_size: get_in(tag, ["details", "parameter_size"]),
      default: tag["name"] == default,
      loaded: tag["name"] in loaded
    }
  end

  defp embedding?(%{"capabilities" => capabilities}) when is_list(capabilities),
    do: "completion" not in capabilities

  defp embedding?(%{"details" => %{"family" => family}}), do: family in @embedding_families
  defp embedding?(_tag), do: false

  # The models in memory now, `[]` when Ollama does not say.
  defp loaded_names do
    case ollama_get("/api/ps") do
      {:ok, %{"models" => models}} when is_list(models) ->
        for %{"name" => name} <- models, do: name

      _unknown ->
        []
    end
  end

  # Whether `model` is in memory already (its call then has no load time).
  defp warm?(model) do
    case ollama_get("/api/ps") do
      {:ok, %{"models" => models}} when is_list(models) ->
        Enum.any?(models, &(&1["name"] == model or &1["model"] == model))

      _unknown ->
        nil
    end
  end

  # Unloads `model` from Ollama's memory when it is an installed chat model.
  # Never an embedding model, never a model that is not listed.
  defp unload(model) do
    with {:ok, %{"models" => tags}} when is_list(tags) <- ollama_get("/api/tags"),
         %{} = tag <- Enum.find(tags, &(&1["name"] == model)),
         false <- embedding?(tag),
         {:ok, %Req.Response{status: 200}} <-
           Req.post(ollama_request(10_000),
             url: "/api/chat",
             json: %{model: model, keep_alive: 0}
           ) do
      true
    else
      _not_unloaded -> false
    end
  end

  defp ollama_request(timeout) do
    config = Ollama.config()

    [base_url: config[:base_url], receive_timeout: timeout, retry: false]
    |> Keyword.merge(config[:req_options])
    |> Req.new()
  end

  defp ollama_get(path) do
    config = Ollama.config()

    case Req.get(ollama_request(5_000), url: path) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Ollama answered HTTP #{status} for #{path}"}

      {:error, exception} ->
        {:error, "Ollama did not answer on #{config[:base_url]}: #{Exception.message(exception)}"}
    end
  end

  defp describe(reason),
    do: reason |> inspect(limit: 8, printable_limit: 200) |> String.slice(0, 300)

  defp config(key),
    do:
      @defaults
      |> Keyword.merge(Application.get_env(:knowseek, __MODULE__, []))
      |> Keyword.fetch!(key)

  defp timeout_seconds do
    ms = config(:model_timeout)
    if rem(ms, 1000) == 0, do: div(ms, 1000), else: Float.round(ms / 1000, 1)
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp elapsed_ms(started), do: now() - started
end
