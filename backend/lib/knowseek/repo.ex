defmodule Knowseek.Repo do
  use Ecto.Repo,
    otp_app: :knowseek,
    adapter: Ecto.Adapters.Postgres
end
