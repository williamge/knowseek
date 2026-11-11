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

  It searches the Cookbook namespace (102, recipes such as
  *Cookbook:Hard Cooked Eggs*) first, then the main namespace, and keeps
  the Cookbook pages first (`search_namespaces`, see `MediaWiki`; ADR 0029).
  A question that matches no recipe gets the main-namespace pages, as
  before; titles keep their `Cookbook:` prefix.

  Candidates are `CC-BY-SA-4.0`, credited to "Wikibooks" with a link to the
  page, `modified: true` and `share: "full"` (ADR 0026). Their
  `monthly_views` are Wikibooks page views: the same unit as Wikipedia's,
  but one to two orders of magnitude smaller for the same subject (ADR 0029).
  `links/2` re-reads the external links of a stored page for the link
  backfill (#88). `link_candidates/2` reads the pages it links to, in the
  main and Cookbook namespaces, for the background crawl (#89).

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
    skip_compilations: true,
    search_namespaces: [102, 0],
    link_namespaces: [0, 102]
  }

  @impl true
  def name, do: @site.name

  @impl true
  def discover(query, opts) do
    if question?(query),
      do: MediaWiki.discover(search_text(query), @site, opts),
      else: {:ok, []}
  end

  @impl true
  def links(document, opts), do: MediaWiki.links(document, @site, opts)

  @impl true
  def link_candidates(document, opts), do: MediaWiki.link_candidates(document, @site, opts)

  @doc """
  The text sent to the Wikibooks search for a question: `query` without its
  question lead-in ("how do I", "how to", "why does", "can I", "what's the
  best way to", ...) and without a trailing `?`. Wikibooks' search matches
  those words too: "how do i cook eggs" finds *General Engineering
  Introduction/Golden Ignorance*, "cook eggs" does not (ADR 0029). If nothing
  is left, `query` is sent as it is.
  """
  @spec search_text(String.t()) :: String.t()
  def search_text(query) do
    stripped =
      query
      |> String.trim()
      |> String.replace(~r/\s*\?+$/u, "")
      |> String.replace(lead_in(), "")
      |> String.trim()

    if stripped == "", do: String.trim(query), else: stripped
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

  # The lead-in of a question, longest first: "how do i", "how to", "why does",
  # "can i", "what's the best way to", ...
  defp lead_in do
    ~r/^(?:how(?:-to|\s+(?:do|does|did|can|could|should|would|to))?(?:\s+(?:i|you|we|one|it))?(?:\s+to)?|why(?:\s+(?:do|does|did|is|are|would|can't|won't))?(?:\s+(?:i|you|we|it))?|(?:can|could|should|would|do)(?:\s+(?:i|you|we|one))?|is\s+it|what(?:'|’)?s\s+the\s+best(?:\s+way)?(?:\s+to)?|what\s+is\s+the\s+best(?:\s+way)?(?:\s+to)?)\b\s*/iu
  end
end
