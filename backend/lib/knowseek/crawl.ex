defmodule Knowseek.Crawl do
  @moduledoc """
  The background crawl (#89, ADR 0033): while the instance is idle it reads
  the links of the pages your searches showed, and scores them.

  A **source page** is a document in the logged results of a search of the
  last `window_days` (never a background page, `Knowseek.Activity.result_pages/1`).
  It earns an **allowance** of link-fetches (`Knowseek.Crawl.Allowance`). Its
  links are read through `Knowseek.Discovery.link_candidates/1` (one request,
  with short descriptions) and scored (`Knowseek.Crawl.Score`): `interest` in
  the searches that showed the page, `novelty` against the pages already
  stored (`Knowseek.Search.count_near/2`), a bonus when the page was a
  search's only result, and a bonus for a link several source pages share.
  The candidates above the bar are kept in `crawl_candidates`
  (`Knowseek.Crawl.Frontier`).

  `Knowseek.Crawl.Scheduler` ticks once a minute and, when `due?/1`, enqueues
  one `Knowseek.Crawl.Worker` job, which runs `step/1`: one action. It reads
  one source page, or, when every source page with allowance has been read
  and the mode is `:on`, fetches the best pending candidate through
  `Knowseek.Discovery.fetch_page/3` (origin `background`), at most
  `pages_per_day` a UTC day. A candidate is checked again right before its
  fetch: it is dropped when it is indexed already, or when the pages stored
  since it was scored have lowered its novelty under the bar. Search always
  wins: an instance that was searched less than `idle_seconds` ago is not
  idle (`Knowseek.Crawl.Idle`). Nothing runs while
  `Knowseek.Activity.hold(:background)` gives a reason (#90, ADR 0034): a
  budget at 90% or low (or unreadable) free disk space.

  Mode (`mode/0`): `:off`, `:preview` (reads and scores, fetches nothing; the
  default) or `:on`.

  The crawl reaches a source only through `Knowseek.Discovery`, the search
  log through `Knowseek.Activity`, and the index through `Knowseek.Documents`
  and `Knowseek.Search`.
  """
  require Logger

  alias Knowseek.Activity
  alias Knowseek.Crawl.{Allowance, Candidate, Frontier, Idle, Score}
  alias Knowseek.{Discovery, Documents, Embeddings, Search}

  @day_seconds 86_400

  @type scored :: %{
          candidate: Candidate.t(),
          shared: float(),
          shared_count: pos_integer(),
          score: float()
        }

  @type action :: :none | {:read, Allowance.source()} | {:fetch, [scored()]}

  @type entry :: %{
          title: String.t(),
          description: String.t() | nil,
          url: String.t(),
          source: %{
            document_id: Ecto.UUID.t(),
            title: String.t() | nil,
            url: String.t() | nil,
            queries: [String.t()]
          },
          interest: float(),
          novelty: float(),
          gap: float(),
          shared: float(),
          shared_count: pos_integer(),
          score: float(),
          document_id: Ecto.UUID.t() | nil,
          fetched_at: DateTime.t() | nil,
          stored_bytes: non_neg_integer() | nil,
          hit: boolean()
        }

  @type overview :: %{
          mode: :off | :preview | :on,
          pages_per_day: pos_integer(),
          fetched_today: non_neg_integer(),
          bar: float(),
          next: [entry()],
          paused: Knowseek.Activity.hold() | nil,
          fetched: [entry()]
        }

  @doc "The crawl mode from config: `:off`, `:preview` (reads and scores, fetches nothing) or `:on` (also fetches)."
  @spec mode() :: :off | :preview | :on
  def mode, do: config()[:mode]

  @doc """
  Whether a step should run now: the mode is not `:off`, no re-embed is
  running (`Documents.reembedding?/0`: novelty would see only the pages
  already redone, ADR 0035), the instance is idle (`Knowseek.Crawl.Idle.idle?/1`),
  no budget holds background work back (`Knowseek.Activity.hold/1`) and
  `next_action/1` is not `:none`. Only reads.
  """
  @spec due?(keyword()) :: boolean()
  def due?(opts \\ []) do
    mode() != :off and not Documents.reembedding?() and Idle.idle?(opts) and
      Activity.hold(:background) == nil and next_action(opts) != :none
  end

  @doc "What `step/1` would do now. Only reads. Option `:now` (tests)."
  @spec next_action(keyword()) :: action()
  def next_action(opts \\ []) do
    if mode() == :off, do: :none, else: opts |> state() |> next()
  end

  @doc """
  Does one action: reads and scores one source page's links, or, in mode
  `:on`, fetches one page. Never raises on a failed request; the next step
  tries again. Does not check idleness (the scheduler does).
  """
  @spec step(keyword()) :: :ok
  def step(opts \\ []) do
    if mode() == :off or Activity.hold(:background) != nil do
      :ok
    else
      state = state(opts)

      case next(state) do
        {:read, source} -> read(source, state)
        {:fetch, ranked} -> fetch(ranked, state)
        :none -> :ok
      end
    end
  end

  @doc """
  What the Crawl page shows: the mode, today's count, the bar, why
  background work is paused (`paused`: `Knowseek.Activity.hold(:background)`,
  or `nil`), the next candidates in the order they would be fetched (in
  `:preview` this is what mode `:on` would fetch) and the last fetched pages,
  newest first. `:limit` (default 50) for each list.
  """
  @spec overview(keyword()) :: overview()
  def overview(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    state = state(opts)
    ranked = state |> rank() |> Enum.take(limit)

    %{
      mode: mode(),
      pages_per_day: config()[:pages_per_day],
      fetched_today: fetched_today(state.now),
      bar: config()[:bar],
      paused: Activity.hold(:background),
      next: entries(ranked, state),
      fetched: limit |> Frontier.recent_fetched() |> fetched_entries(state)
    }
  end

  @doc "The crawl counters for `/stats`."
  @spec stats(keyword()) :: %{
          mode: :off | :preview | :on,
          pages_per_day: pos_integer(),
          fetched_today: non_neg_integer(),
          fetched: non_neg_integer(),
          links_read: non_neg_integer(),
          candidates: non_neg_integer(),
          stored_bytes: non_neg_integer()
        }
  def stats(opts \\ []) do
    totals = Frontier.totals()

    Map.merge(totals, %{
      mode: mode(),
      pages_per_day: config()[:pages_per_day],
      fetched_today: fetched_today(now(opts))
    })
  end

  @doc """
  Forgets what was derived from the search history: the link lists and the
  pending candidates. Fetched pages and their records stay. Returns the number
  of candidates deleted.
  """
  @spec clear_pending() :: {:ok, non_neg_integer()}
  def clear_pending, do: Frontier.clear_pending()

  # --- State -------------------------------------------------------------

  # What every function starts from: the source pages of the log (those whose
  # document still exists), the link lists already read, and the allowance
  # each source page has left.
  defp state(opts) do
    now = now(opts)
    config = config()

    pages = Activity.result_pages(days: config[:window_days], now: now)
    summaries = Documents.summaries(Map.keys(pages))

    sources =
      pages
      |> Map.take(Map.keys(summaries))
      |> Allowance.sources(config)

    ids = Enum.map(sources, & &1.document_id)
    spent = Frontier.spent(DateTime.add(now, -config[:window_days] * @day_seconds, :second))

    %{
      now: now,
      config: config,
      sources: sources,
      summaries: summaries,
      model_since: Documents.model_since(),
      read: Frontier.source_pages(ids),
      live: Enum.filter(sources, &(allowance(&1, spent) > 0))
    }
  end

  defp allowance(source, spent), do: max(source.earned - Map.get(spent, source.document_id, 0), 0)

  defp now(opts) do
    opts |> Keyword.get_lazy(:now, fn -> DateTime.utc_now() end) |> DateTime.truncate(:second)
  end

  defp config, do: Application.fetch_env!(:knowseek, __MODULE__)

  defp fetched_today(now) do
    start = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")
    Frontier.fetched_since(start)
  end

  # The first source page, in reading order, with allowance left whose links
  # were not read yet or were read more than `reread_days` ago. Else, in mode
  # `:on` and under today's cap, the ranked candidates.
  defp next(state) do
    reread_before = DateTime.add(state.now, -state.config[:reread_days] * @day_seconds, :second)

    case Enum.find(state.live, &unread?(&1, state.read, reread_before, state.model_since)) do
      nil -> next_fetch(state)
      source -> {:read, source}
    end
  end

  defp next_fetch(state) do
    if mode() == :on and fetched_today(state.now) < state.config[:pages_per_day] do
      case rank(state) do
        [] -> :none
        ranked -> {:fetch, ranked}
      end
    else
      :none
    end
  end

  # A source page read before the current embedding model's row was created
  # is read again: its candidates were scored with another model (ADR 0035).
  defp unread?(source, read, reread_before, model_since) do
    case Map.get(read, source.document_id) do
      nil ->
        true

      %{read_at: read_at} ->
        DateTime.compare(read_at, reread_before) == :lt or
          (model_since != nil and DateTime.compare(read_at, model_since) == :lt)
    end
  end

  # --- Reading a source page ---------------------------------------------

  # The links of one source page: the queries are embedded first, so that a
  # provider that is down stops the step before any request to the site.
  defp read(source, state) do
    Frontier.prune(Enum.map(state.sources, & &1.document_id))

    with %Documents.Document{} = document <- Documents.get_document(source.document_id),
         {:ok, query_vectors} <- Embeddings.embed(source.queries, input_type: :query),
         {:ok, links} <- Discovery.link_candidates(document),
         {:ok, rows} <- score_links(document, links, source, query_vectors, state) do
      link_ids = Enum.map(links, & &1.page_id)

      Frontier.put_source(
        %{
          document_id: document.id,
          site: document.source,
          link_ids: link_ids,
          links: length(link_ids),
          kept: length(rows),
          read_at: state.now
        },
        rows
      )
    else
      nil ->
        :ok

      {:error, reason} ->
        Logger.warning("crawl: reading links of #{source.document_id} failed: #{inspect(reason)}")
        :ok
    end
  end

  # The candidates worth keeping, as rows of `crawl_candidates`, best first.
  defp score_links(document, links, source, query_vectors, state) do
    config = state.config
    ids = Enum.map(links, & &1.page_id)

    skip =
      MapSet.union(
        Documents.indexed_page_ids(document.source, ids),
        Frontier.settled_page_ids(document.source, ids)
      )

    fresh = Enum.reject(links, &MapSet.member?(skip, &1.page_id))
    gap = if source.gap, do: config[:gap_bonus], else: 0.0

    with {:ok, vectors} <-
           Embeddings.embed(Enum.map(fresh, &Score.text(&1.title, &1.description)),
             input_type: :document
           ) do
      rows =
        fresh
        |> Enum.zip(vectors)
        |> Enum.flat_map(fn {link, vector} ->
          interest = Score.interest(vector, query_vectors)
          row(link, vector, interest, gap, document, state)
        end)
        |> Enum.sort_by(&{-&1.score, &1.page_id})
        |> Enum.take(config[:max_candidates])

      {:ok, rows}
    end
  end

  # Only a link above the interest floor is looked up in the index, and kept
  # when it could pass the bar with the largest shared bonus.
  defp row(link, vector, interest, gap, document, %{config: config, now: now}) do
    if interest >= config[:interest_floor] do
      near = Search.count_near(vector, limit: config[:novelty_full_at])
      novelty = Score.novelty(near, config[:novelty_full_at])
      base = Score.base(interest, novelty, gap)

      if base + config[:shared_bonus] >= config[:bar] do
        [
          %{
            source_document_id: document.id,
            page_id: link.page_id,
            site: document.source,
            title: link.title,
            description: link.description,
            url: link.url,
            interest: interest,
            novelty: novelty,
            gap: gap,
            shared: 0.0,
            shared_count: 1,
            score: base,
            state: "pending",
            scored_at: now
          }
        ]
      else
        []
      end
    else
      []
    end
  end

  # --- Fetching a page ---------------------------------------------------

  # Goes through the first `rechecks_per_step` ranked candidates and stops at
  # the first one that ends in a request. Each is checked again right before
  # it could be fetched: the page may have been stored meanwhile, and the
  # pages stored since this candidate was scored may have used up its
  # novelty. This is what makes a topic fill up: each fetched page lowers the
  # novelty of its neighbours.
  defp fetch(ranked, state) do
    ranked |> Enum.take(state.config[:rechecks_per_step]) |> fetch_first(state)
  end

  defp fetch_first([], _state), do: :ok

  defp fetch_first([%{candidate: candidate} = scored | rest], state) do
    if MapSet.size(Documents.indexed_page_ids(candidate.site, [candidate.page_id])) > 0 do
      Frontier.delete_page(candidate.site, candidate.page_id)
      fetch_first(rest, state)
    else
      case recheck(scored, state) do
        {:ok, rechecked} ->
          request(rechecked, state)

        :dropped ->
          Frontier.delete(candidate)
          fetch_first(rest, state)

        {:error, reason} ->
          Logger.warning("crawl: embedding #{candidate.title} failed: #{inspect(reason)}")
          :ok
      end
    end
  end

  # The candidate's novelty and score as they are now, with the shared bonus
  # of the ranking. `:dropped` when the score is under the bar.
  defp recheck(%{candidate: candidate} = scored, %{config: config}) do
    with {:ok, [vector]} <-
           Embeddings.embed([Score.text(candidate.title, candidate.description)],
             input_type: :document
           ) do
      near = Search.count_near(vector, limit: config[:novelty_full_at])
      novelty = Score.novelty(near, config[:novelty_full_at])
      score = Score.base(candidate.interest, novelty, candidate.gap) + scored.shared

      if score >= config[:bar],
        do: {:ok, %{scored | candidate: %{candidate | novelty: novelty}, score: score}},
        else: :dropped
    end
  end

  defp request(%{candidate: candidate} = scored, state) do
    case Discovery.fetch_page(candidate.site, candidate.page_id, candidate.url) do
      {:ok, %Documents.Document{origin: "background"} = document} ->
        Frontier.mark_fetched(candidate, %{
          document_id: document.id,
          novelty: candidate.novelty,
          shared: scored.shared,
          shared_count: scored.shared_count,
          score: scored.score,
          stored_bytes: Documents.stored_bytes(document.id),
          fetched_at: state.now
        })

      {:ok, %Documents.Document{}} ->
        # A search stored the page under its own origin meanwhile.
        Frontier.delete_page(candidate.site, candidate.page_id)

      {:ok, nil} ->
        Frontier.mark_skipped(candidate)

      {:error, :not_allowed} ->
        Frontier.mark_skipped(candidate)

      {:error, reason} ->
        Logger.warning("crawl: fetching #{candidate.title} failed: #{inspect(reason)}")
        Frontier.mark_failed(candidate, state.now)
    end
  end

  # --- Ranking -----------------------------------------------------------

  # The pending candidates of the source pages with allowance left, in the
  # order they would be fetched: with the shared bonus, at the bar or above,
  # best first. A page that two source pages link to is listed once.
  defp rank(state) do
    config = state.config
    retry_before = DateTime.add(state.now, -config[:retry_minutes] * 60, :second)

    # Candidates scored before the current model's row was created were scored
    # with another model: they are not ranked until their source page is read
    # again (ADR 0035).
    pending =
      state.live
      |> Enum.map(& &1.document_id)
      |> Frontier.pending(retry_before)
      |> Enum.reject(&scored_before?(&1.scored_at, state.model_since))

    freq = link_frequencies(state.read)
    counts = Map.new(state.read, fn {id, row} -> {id, counts(row, freq)} end)

    pending
    |> Enum.map(&scored(&1, freq, counts, config))
    |> Enum.filter(&(&1.score >= config[:bar]))
    |> Enum.sort_by(& &1.candidate.page_id)
    |> Enum.sort_by(& &1.candidate.scored_at, DateTime)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.uniq_by(&{&1.candidate.site, &1.candidate.page_id})
  end

  defp scored_before?(_scored_at, nil), do: false
  defp scored_before?(scored_at, since), do: DateTime.compare(scored_at, since) == :lt

  # Per site, in how many read source pages each page id is linked.
  defp link_frequencies(read) do
    Enum.reduce(read, %{}, fn {_id, %{site: site, link_ids: link_ids}}, acc ->
      Map.update(acc, site, Enum.frequencies(link_ids), &add_links(&1, link_ids))
    end)
  end

  defp add_links(site_freq, link_ids),
    do: Enum.reduce(link_ids, site_freq, &Map.update(&2, &1, 1, fn n -> n + 1 end))

  defp counts(%{site: site, link_ids: link_ids}, freq),
    do: Enum.map(link_ids, &Map.fetch!(freq[site], &1))

  defp scored(candidate, freq, counts, config) do
    count = freq |> Map.get(candidate.site, %{}) |> Map.get(candidate.page_id, 1)
    rarity = Score.rarity(count, Map.get(counts, candidate.source_document_id, []))
    shared = Score.shared(count, rarity, config[:shared_bonus])
    base = Score.base(candidate.interest, candidate.novelty, candidate.gap)

    %{candidate: candidate, shared: shared, shared_count: count, score: base + shared}
  end

  # The entries of `overview/1`. `next` entries come from `rank/1`; a fetched
  # entry shows the stored document's title and URL, and the scores that
  # decided the fetch.
  defp entries(ranked, state) do
    ranked
    |> Enum.map(fn %{candidate: candidate} = scored ->
      {candidate,
       %{shared: scored.shared, shared_count: scored.shared_count, score: scored.score}}
    end)
    |> build_entries(state, MapSet.new())
  end

  defp fetched_entries(candidates, state) do
    hits =
      candidates |> Enum.flat_map(&List.wrap(&1.document_id)) |> Activity.hit_documents()

    candidates
    |> Enum.map(&{&1, %{shared: &1.shared, shared_count: &1.shared_count, score: &1.score}})
    |> build_entries(state, hits)
  end

  defp build_entries(pairs, %{sources: sources, summaries: summaries}, hits) do
    queries = Map.new(sources, &{&1.document_id, &1.queries})

    ids =
      pairs
      |> Enum.flat_map(fn {candidate, _parts} ->
        [candidate.source_document_id | List.wrap(candidate.document_id)]
      end)
      |> Enum.reject(&Map.has_key?(summaries, &1))
      |> Enum.uniq()

    summaries = Map.merge(summaries, Documents.summaries(ids))

    Enum.map(pairs, fn {candidate, parts} ->
      source = Map.get(summaries, candidate.source_document_id, %{})
      page = Map.get(summaries, candidate.document_id, %{})

      %{
        title: page[:title] || candidate.title,
        description: candidate.description,
        url: page[:url] || candidate.url,
        source: %{
          document_id: candidate.source_document_id,
          title: source[:title],
          url: source[:url],
          queries: Map.get(queries, candidate.source_document_id, [])
        },
        interest: candidate.interest,
        novelty: candidate.novelty,
        gap: candidate.gap,
        shared: parts.shared,
        shared_count: parts.shared_count,
        score: parts.score,
        document_id: candidate.document_id,
        fetched_at: candidate.fetched_at,
        stored_bytes: candidate.stored_bytes,
        hit: MapSet.member?(hits, candidate.document_id)
      }
    end)
  end
end
