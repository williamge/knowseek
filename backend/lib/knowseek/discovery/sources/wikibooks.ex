defmodule Knowseek.Discovery.Sources.Wikibooks do
  @moduledoc """
  Discovery source for English Wikibooks, through the MediaWiki Action API
  (`Knowseek.Discovery.Sources.MediaWiki`, which documents the requests and
  the candidates). Wikibooks gives steps where Wikipedia gives a description
  (ADR 0029).

  It runs only for a question (`question?/1`): for "Barack Obama" its search
  returns off-topic book pages, so it sends no request and returns no
  candidates. It skips compilations such as print versions, pages built
  from the book's chapters, since the chapters are pages of their own
  (`skip_compilations`, see `MediaWiki`).

  Candidates are `CC-BY-SA-4.0`, credited to "Wikibooks" with a link to the
  page, `modified: true` and `share: "full"` (ADR 0026). Their
  `monthly_views` are Wikibooks page views: the same unit as Wikipedia's,
  but one to two orders of magnitude smaller for the same subject (ADR 0029).

  Configuration (all optional; see `Knowseek.Discovery.Sources.MediaWiki`):

      config :knowseek, Knowseek.Discovery.Sources.Wikibooks,
        base_url: "https://en.wikibooks.org/w/api.php",
        limit: 3,
        max_chars: 40_000,
        user_agent: "...",
        req_options: []
  """
  @behaviour Knowseek.Discovery.Source

  alias Knowseek.Discovery.Sources.MediaWiki

  @site %{
    name: "wikibooks",
    base_url: "https://en.wikibooks.org/w/api.php",
    license: "CC-BY-SA-4.0",
    credit: "Wikibooks",
    config: __MODULE__,
    skip_compilations: true
  }

  @impl true
  def name, do: @site.name

  @impl true
  def discover(query, _opts) do
    if question?(query), do: MediaWiki.discover(query, @site), else: {:ok, []}
  end

  @doc """
  Whether `query` is a question, the queries a how-to source answers: it ends
  with `?`, or it starts with one of these words (any case): how, why, can,
  could, should, do I, is it, what's the best, what is the best.

  The words name a method, a reason or advice. Other "what" and "who"
  questions ask what something is, which Wikipedia answers, unless they end
  with `?`.
  """
  @spec question?(String.t()) :: boolean()
  def question?(query) do
    query = String.trim(query)
    String.ends_with?(query, "?") or Regex.match?(question_start(), query)
  end

  # A word, not a prefix: "cannes" and "howard" are not questions. `\b` also
  # ends "how" in "how-to".
  defp question_start do
    ~r/^(how|why|can|could|should|do i|is it|what(?:'|’)?s the best|what is the best)\b/iu
  end
end
