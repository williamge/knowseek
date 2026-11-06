defmodule Knowseek.Repo.Migrations.AddLicenseFieldsToDocuments do
  use Ecto.Migration

  # Each document's license, who to credit, whether its text differs from the
  # source's, and what a peer may receive (ADR 0026). Unknown is
  # `LicenseRef-unknown` and `share = 'none'`.
  def up do
    alter table(:documents) do
      add :license, :string, null: false, default: "LicenseRef-unknown"
      add :attribution, :map
      add :modified, :boolean, null: false, default: false
      add :share, :string, null: false, default: "none"
    end

    create constraint(:documents, :documents_share_check,
             check: "share IN ('full', 'pointer', 'none')"
           )

    # Wikipedia's text is CC BY-SA 4.0 (or GFDL), stored as a plain-text
    # extract that may be cut, and a link to the page credits its authors.
    # Every other existing row (manual, seed) stays unknown.
    execute("""
    UPDATE documents
    SET license = 'CC-BY-SA-4.0',
        attribution = jsonb_build_object('url', url, 'credit', 'Wikipedia', 'authors', '[]'::jsonb),
        modified = true,
        share = 'full'
    WHERE source = 'wikipedia'
    """)
  end

  def down do
    drop constraint(:documents, :documents_share_check)

    alter table(:documents) do
      remove :license
      remove :attribution
      remove :modified
      remove :share
    end
  end
end
