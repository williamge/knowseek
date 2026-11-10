defmodule Knowseek.Search.FtsQuery do
  @moduledoc """
  Turns a user's query into an FTS5 `MATCH` expression (ADR 0030).

  FTS5 parses its own query language, and raw input breaks it: `what's new`
  is a syntax error, and a bare `AND`, `NEAR` or `*` is an operator. This
  module never passes user text through as syntax. It reads the query the way
  Postgres's `websearch_to_tsquery` did, which the index used before:

    * Words are split the way the `unicode61` tokenizer splits them (letters
      and digits; everything else separates). Every remaining word is a
      double-quoted FTS5 string, and the words are ANDed.
    * Words on Postgres's English stop-word list (`english.stop`) are
      dropped, outside phrases. FTS5 indexes every word, so a stop word would
      otherwise have to appear in the chunk: "why is the sky blue" would need
      "why", "is" and "the" as well as "sky" and "blue".
    * `"a quoted phrase"` is an FTS5 phrase. It keeps its stop words, so it
      matches those words in that order.
    * `or` between two words or phrases matches either. It binds tighter than
      the implicit AND, as in `websearch_to_tsquery`: `a b or c` is
      `a AND (b OR c)`.
    * `-word` or `-"a phrase"` excludes chunks that contain it (a stop word
      after `-` is dropped, not excluded).

  `build/1` returns `nil` when nothing is left to match (empty, only stop
  words, only punctuation, or only exclusions): the query then has no
  full-text half. FTS5 cannot express "everything except", which is also why
  a query of exclusions alone matches nothing.
  """

  # Postgres's `english.stop` (share/tsearch_data), the list the old
  # `to_tsvector('english', ...)` index used.
  @stop_words ~w(
    i me my myself we our ours ourselves you your yours yourself yourselves
    he him his himself she her hers herself it its itself they them their
    theirs themselves what which who whom this that these those am is are was
    were be been being have has had having do does did doing a an the and but
    if or because as until while of at by for with about against between into
    through during before after above below to from up down in out on off
    over under again further then once here there when where why how all any
    both each few more most other some such no nor not only own same so than
    too very s t can will just don should now
  ) |> MapSet.new()

  # Separators of the `unicode61` tokenizer: everything but letters and digits.
  @separator ~r/[^\p{L}\p{N}]+/u

  @doc "The words that are dropped outside phrases."
  @spec stop_words() :: MapSet.t(String.t())
  def stop_words, do: @stop_words

  @doc """
  The FTS5 expression for `query`, or `nil` when nothing is left to match.

      iex> Knowseek.Search.FtsQuery.build("why is the sky blue")
      ~s("sky" AND "blue")

      iex> Knowseek.Search.FtsQuery.build("what's new")
      ~s("new")
  """
  @spec build(String.t()) :: String.t() | nil
  def build(query) when is_binary(query) do
    query
    |> lex()
    |> group_or()
    |> render()
  end

  # Tokens: {:atom, negated?, words} for a word or a phrase, and :or.
  defp lex(query) do
    ~r/(-?)"([^"]*)"?|(\S+)/u
    |> Regex.scan(query, capture: :all_but_first)
    |> Enum.flat_map(&token/1)
  end

  defp token([negation, phrase]), do: phrase_token(negation == "-", phrase)

  defp token(["", "", word]) do
    cond do
      String.downcase(word) == "or" -> [:or]
      String.starts_with?(word, "-") -> word_tokens(true, String.slice(word, 1..-1//1))
      true -> word_tokens(false, word)
    end
  end

  defp phrase_token(negated?, phrase) do
    case words(phrase) do
      [] -> []
      words -> [{:atom, negated?, words}]
    end
  end

  # A bare word that the tokenizer splits ("e-mail", "what's") is several
  # words. Stop words are dropped, as `websearch_to_tsquery` drops them; the
  # rest are ANDed, or, negated, excluded together as one phrase.
  defp word_tokens(negated?, word) do
    case Enum.reject(words(word), &MapSet.member?(@stop_words, &1)) do
      [] -> []
      words when negated? -> [{:atom, true, words}]
      words -> for w <- words, do: {:atom, false, [w]}
    end
  end

  defp words(text) do
    text |> String.downcase() |> String.split(@separator, trim: true)
  end

  # Joins `a or b or c` into one group; drops an `or` with no atom on one side.
  defp group_or(tokens), do: group_or(tokens, [])

  defp group_or([], groups), do: Enum.reverse(groups)

  defp group_or([{:atom, _, _} = right | rest], [{:pending_or, left} | groups]),
    do: group_or(rest, [left ++ [right] | groups])

  defp group_or([{:atom, _, _} = atom | rest], groups), do: group_or(rest, [[atom] | groups])

  defp group_or([:or | rest], [{:pending_or, _} | _] = groups), do: group_or(rest, groups)

  defp group_or([:or | rest], [group | groups]),
    do: group_or(rest, [{:pending_or, group} | groups])

  defp group_or([:or | rest], []), do: group_or(rest, [])

  # A trailing `or` leaves its left side as an ordinary group.
  defp render(groups) do
    groups =
      Enum.map(groups, fn
        {:pending_or, group} -> group
        group -> group
      end)

    {positive, negative} =
      Enum.reduce(groups, {[], []}, fn group, {positive, negative} ->
        {excluded, included} = Enum.split_with(group, fn {:atom, negated?, _} -> negated? end)
        positive = if included == [], do: positive, else: [included | positive]
        {positive, Enum.reverse(excluded, negative)}
      end)

    case {Enum.reverse(positive), Enum.reverse(negative)} do
      {[], _negative} ->
        nil

      {positive, []} ->
        Enum.map_join(positive, " AND ", &render_group/1)

      {positive, negative} ->
        "(" <>
          Enum.map_join(positive, " AND ", &render_group/1) <>
          ")" <> Enum.map_join(negative, "", &(" NOT " <> render_atom(&1)))
    end
  end

  defp render_group([atom]), do: render_atom(atom)
  defp render_group(atoms), do: "(" <> Enum.map_join(atoms, " OR ", &render_atom/1) <> ")"

  # Only letters and digits remain, so the words need no escaping.
  defp render_atom({:atom, _negated?, words}), do: ~s(") <> Enum.join(words, " ") <> ~s(")
end
