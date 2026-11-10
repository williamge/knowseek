defmodule Knowseek.ReleaseRepo do
  @moduledoc """
  A second repo for `Knowseek.ReleaseTest`. It points at a throwaway SQLite
  file and reuses the migrations of `Knowseek.Repo` (`priv: "priv/repo"`).
  """
  use Ecto.Repo, otp_app: :knowseek, adapter: Ecto.Adapters.SQLite3
end
