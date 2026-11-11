defmodule Knowseek.Documents.Document do
  @moduledoc """
  A piece of source content: a web page, an article, a manual note.

  The `url` is the identity of a document. It is stored in canonical form
  (`Knowseek.Documents.URL`). Ingesting the same URL again updates the
  existing row. Other URLs that served the same body are recorded in
  `Knowseek.Documents.DocumentAlias`.

  `monthly_views` is an optional importance signal: how often the page that
  the document came from is read, per 30 days. It is `nil` when the source has
  no such figure. `Knowseek.Search` turns it into a ranking prior (ADR 0018).

  `source_updated_at` is when the source says the page was last edited (for
  Wikipedia, the latest revision timestamp). It is `nil` when the source does
  not say. It is not `published_at` (first published) and not `fetched_at`
  (when Knowseek last saw the content).

  `license`, `attribution`, `modified` and `share` say under which terms the
  text may be shown and passed on (ADR 0026). `license` is an SPDX id
  (`CC-BY-SA-4.0`), `attribution` who to credit (`Knowseek.Documents.Attribution`,
  or `nil`), `modified` whether the text differs from the source's, and
  `share` what a peer may receive: `full`, `pointer` or `none`. The source sets
  them at ingest. Unknown is `LicenseRef-unknown`, no attribution, and `none`.

  `origin` says why the page first entered the index: `search` (search-time
  discovery), `background` (a crawl, #89) or `manual`. `origin_query` is the
  normalized query whose discovery fetched a `search` page, `nil` when unknown.
  Both are write-once: `ingest_changeset/2` casts them only for a new document
  (#96, ADR 0031).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Knowseek.Documents.{Attribution, URL}

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
    field :monthly_views, :integer
    field :source_updated_at, :utc_datetime
    field :license, :string, default: "LicenseRef-unknown"
    embeds_one :attribution, Attribution, on_replace: :delete
    field :modified, :boolean, default: false
    field :share, :string, default: "none"
    field :origin, :string, default: "manual"
    field :origin_query, :string

    has_many :chunks, Knowseek.Documents.Chunk

    timestamps(type: :utc_datetime)
  end

  @shares ~w(full pointer none)
  @origins ~w(search background manual)

  @fields [
    :url,
    :title,
    :body,
    :source,
    :published_at,
    :fetched_at,
    :metadata,
    :monthly_views,
    :source_updated_at,
    :license,
    :modified,
    :share
  ]

  @doc """
  Changeset for ingestion. Canonicalizes the `url`, fills in `content_hash`
  and `fetched_at`, and generates a content-addressed URL when the caller does
  not give one. `:origin` and `:origin_query` are cast only for a new document.
  """
  def ingest_changeset(document, attrs) do
    fields = if document.id, do: @fields, else: @fields ++ [:origin, :origin_query]

    document
    |> cast(attrs, fields)
    |> cast_embed(:attribution)
    |> validate_number(:monthly_views, greater_than_or_equal_to: 0)
    |> validate_inclusion(:share, @shares)
    |> check_constraint(:share, name: :documents_share_check)
    |> validate_inclusion(:origin, @origins)
    |> check_constraint(:origin, name: :documents_origin_check)
    |> validate_required([:body, :source])
    |> update_change(:url, &URL.canonicalize/1)
    |> put_content_hash()
    |> put_default_url()
    |> put_default_fetched_at()
    |> validate_required([:url, :content_hash, :fetched_at, :license, :modified, :share, :origin])
    |> unique_constraint(:url)
  end

  @doc "True when `url` was generated from the body, not given by the caller."
  def content_url?("urn:knowseek:sha256:" <> _), do: true
  def content_url?(_), do: false

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
