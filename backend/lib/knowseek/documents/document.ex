defmodule Knowseek.Documents.Document do
  @moduledoc """
  A piece of source content: a web page, an article, a manual note.

  The `url` is the identity of a document. Ingesting the same URL again
  updates the existing row.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "documents" do
    field :url, :string
    field :title, :string
    field :body, :string
    field :source, :string
    field :content_hash, :string
    field :published_at, :utc_datetime
    field :fetched_at, :utc_datetime
    field :metadata, :map, default: %{}

    has_many :chunks, Knowseek.Documents.Chunk

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for ingestion. Fills in `content_hash` and `fetched_at`, and
  generates a content-addressed URL when the caller does not give one.
  """
  def ingest_changeset(document, attrs) do
    document
    |> cast(attrs, [:url, :title, :body, :source, :published_at, :fetched_at, :metadata])
    |> validate_required([:body, :source])
    |> put_content_hash()
    |> put_default_url()
    |> put_default_fetched_at()
    |> validate_required([:url, :content_hash, :fetched_at])
    |> unique_constraint(:url)
  end

  @doc "SHA-256 of the body, hex encoded."
  def hash_body(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp put_content_hash(changeset) do
    case get_change(changeset, :body) do
      nil -> changeset
      body -> put_change(changeset, :content_hash, hash_body(body))
    end
  end

  defp put_default_url(changeset) do
    case {get_field(changeset, :url), get_field(changeset, :content_hash)} do
      {nil, nil} -> changeset
      {nil, hash} -> put_change(changeset, :url, "urn:knowseek:sha256:" <> hash)
      _ -> changeset
    end
  end

  # Uses get_change, not get_field: a re-ingested document gets a new
  # fetched_at unless the caller gives one.
  defp put_default_fetched_at(changeset) do
    case get_change(changeset, :fetched_at) do
      nil -> put_change(changeset, :fetched_at, DateTime.utc_now(:second))
      _ -> changeset
    end
  end
end
