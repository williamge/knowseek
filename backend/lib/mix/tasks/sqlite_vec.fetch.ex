defmodule Mix.Tasks.SqliteVec.Fetch do
  @shortdoc "Downloads the pinned sqlite-vec extension into priv/sqlite_vec"

  @moduledoc """
  Downloads the sqlite-vec loadable extension that `Knowseek.Repo` loads into
  every connection (ADR 0030), and checks it against a pinned SHA-256.

      mix sqlite_vec.fetch

  The extension comes from the project's GitHub release (the hex package
  `sqlite_vec` is frozen), one archive per platform. The archive's SHA-256
  must match the digest listed here, which is the `digest` GitHub publishes
  for the release asset. A mismatch stops the task and writes nothing.

  The library lands in `priv/sqlite_vec/` (git-ignored) as `vec0.dylib`
  (macOS) or `vec0.so` (Linux). The task does nothing when that file is there
  and `priv/sqlite_vec/VERSION` names the pinned asset, so `setup`, `test`
  and `ecto.migrate` run it first. It needs the network only the first time.

  To upgrade: change `@version`, then replace every digest with the one of
  the new release (`gh api repos/asg017/sqlite-vec/releases/tags/v<version>
  --jq '.assets[] | "\\(.name) \\(.digest)"'`). A new platform needs its own
  entry.
  """
  use Mix.Task

  @version "0.1.9"

  # {OS, CPU} => {asset suffix, SHA-256 of the .tar.gz}.
  @assets %{
    {:darwin, :aarch64} =>
      {"macos-aarch64", "8282126333399ddfe98bbbcc7a1936e7252625aac49df056a98be602e46bfd29"},
    {:linux, :x86_64} =>
      {"linux-x86_64", "b959baa1d8dc88861b1edb337b8587178cdcb12d60b4998f9d10b6a82052d5d7"},
    {:linux, :aarch64} =>
      {"linux-aarch64", "ea03d39541e478fab5974253c461e1cb5d77742f69e40cf96e3fad5bc309a37c"}
  }

  @impl Mix.Task
  def run(_args) do
    platform = platform()

    {suffix, sha256} =
      Map.get(@assets, platform) ||
        Mix.raise(
          "sqlite-vec #{@version}: no pinned build for #{inspect(platform)}. " <>
            "Add its asset and SHA-256 to #{inspect(__MODULE__)}."
        )

    asset = "sqlite-vec-#{@version}-loadable-#{suffix}.tar.gz"
    dir = Path.join(Path.dirname(Mix.Project.project_file()), "priv/sqlite_vec")
    library = "vec0" <> library_extension(platform)
    stamp = Path.join(dir, "VERSION")

    if File.exists?(Path.join(dir, library)) and File.read(stamp) == {:ok, asset <> "\n"} do
      :ok
    else
      fetch(asset, sha256, library, dir, stamp)
    end
  end

  defp fetch(asset, sha256, library, dir, stamp) do
    url = "https://github.com/asg017/sqlite-vec/releases/download/v#{@version}/#{asset}"
    Mix.shell().info("Downloading #{url}")
    {:ok, _} = Application.ensure_all_started(:req)

    # `raw: true`: keep the archive's bytes as they are (no gunzip, no untar).
    body =
      case Req.get(url, raw: true, receive_timeout: 60_000, redirect_log_level: false) do
        {:ok, %Req.Response{status: 200, body: body}} -> body
        {:ok, %Req.Response{status: status}} -> Mix.raise("#{url}: HTTP #{status}")
        {:error, error} -> Mix.raise("#{url}: #{Exception.message(error)}")
      end

    actual = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    if actual != sha256 do
      Mix.raise("#{asset}: SHA-256 is #{actual}, expected #{sha256}. Nothing was written.")
    end

    {:ok, files} = :erl_tar.extract({:binary, body}, [:compressed, :memory])

    content =
      Enum.find_value(files, fn {name, content} ->
        if Path.basename(to_string(name)) == library, do: content
      end) || Mix.raise("#{asset} has no #{library}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, library), content)
    File.write!(stamp, asset <> "\n")

    Mix.shell().info(
      "sqlite-vec #{@version}: #{Path.join(dir, library)} (archive SHA-256 #{actual})"
    )
  end

  defp platform do
    os =
      case :os.type() do
        {:unix, :darwin} -> :darwin
        {:unix, :linux} -> :linux
        {family, name} -> {family, name}
      end

    arch =
      case :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") do
        [cpu | _] when cpu in ["aarch64", "arm64"] -> :aarch64
        [cpu | _] when cpu in ["x86_64", "amd64"] -> :x86_64
        [cpu | _] -> cpu
      end

    {os, arch}
  end

  defp library_extension({:darwin, _}), do: ".dylib"
  defp library_extension(_), do: ".so"
end
