defmodule Knowseek.Discovery.CountingSource do
  @moduledoc "A discovery source for tests. Reports 1,000 downloaded bytes twice and returns one candidate."
  @behaviour Knowseek.Discovery.Source

  @impl true
  def name, do: "counting"

  @impl true
  def discover(query, opts) do
    opts[:on_bytes].(1_000)
    opts[:on_bytes].(1_000)

    {:ok,
     [
       %{
         url: "https://counting.example/#{URI.encode_www_form(query)}",
         title: "About #{query}",
         body: "This document explains #{query} in detail."
       }
     ]}
  end
end
