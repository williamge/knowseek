defmodule Knowseek.Documents.Vector do
  @moduledoc """
  An embedding as sqlite-vec stores it: float32 values, little-endian, in a
  BLOB. In Elixir it is a list of floats.

  sqlite-vec reads a TEXT value as a JSON array, so a vector must be bound as
  a BLOB: this type dumps to `:binary`, which the SQLite adapter binds as one.
  A raw query binds `{:blob, encode(vector)}`.
  """
  use Ecto.Type

  @impl true
  def type, do: :binary

  @impl true
  def cast(vector) when is_list(vector), do: {:ok, vector}
  def cast(_), do: :error

  @impl true
  def dump(vector) when is_list(vector), do: {:ok, encode(vector)}
  def dump(_), do: :error

  @impl true
  def load(blob) when is_binary(blob), do: {:ok, decode(blob)}
  def load(_), do: :error

  @doc "The quantization recorded with a model (`embedding_models.quantization`): `float32`."
  @spec quantization() :: String.t()
  def quantization, do: "float32"

  @doc "Encodes a list of numbers as float32 little-endian."
  @spec encode([number()]) :: binary()
  def encode(vector), do: for(x <- vector, into: <<>>, do: <<x::float-32-little>>)

  @doc "Decodes float32 little-endian into a list of floats."
  @spec decode(binary()) :: [float()]
  def decode(blob), do: for(<<x::float-32-little <- blob>>, do: x)
end
