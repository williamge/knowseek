defmodule Knowseek.Discovery.LinkSource do
  @moduledoc """
  A discovery source for tests, named `"links"`, that reports outgoing links:
  two blocked URLs on one host, an allowed one and a `mailto:`. `links/2`
  adds a third blocked URL, and reports 700 downloaded bytes through
  `:on_bytes` when it is given one.
  """
  @behaviour Knowseek.Discovery.Source

  @blocked ["https://example.org/a", "http://www.Example.org/b#frag"]
  @links @blocked ++ ["https://en.wikipedia.org/wiki/Elsewhere", "mailto:someone@example.org"]

  @impl true
  def name, do: "links"

  @impl true
  def discover(query, _opts) do
    {:ok,
     [
       %{
         url: "https://links.example/#{URI.encode_www_form(query)}",
         title: "Links about #{query}",
         body: "This page about #{query} has links.",
         links: @links
       }
     ]}
  end

  @impl true
  def links(_document, opts) do
    if on_bytes = opts[:on_bytes], do: on_bytes.(700)
    {:ok, @links ++ ["https://other.example/c"]}
  end
end
