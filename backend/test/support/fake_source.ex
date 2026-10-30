defmodule Knowseek.Discovery.FakeSource do
  @moduledoc "A discovery source for tests. Returns one document that echoes the query."
  @behaviour Knowseek.Discovery.Source

  @impl true
  def name, do: "fake"

  @impl true
  def discover(query, _opts) do
    {:ok,
     [
       %{
         url: "https://fake.example/#{URI.encode_www_form(query)}",
         title: "About #{query}",
         body: "This document explains #{query} in detail."
       }
     ]}
  end
end
