defmodule Pux.DKIMSigner do
  @moduledoc """
  Test-only DKIM signer. Canonicalisation is written independently of `Pux.DKIM`
  so the two don't share bugs.
  """

  alias Pux.DKIMTestResolver

  def rsa_key do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    {:SubjectPublicKeyInfo, der, _} = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)
    %{alg: "rsa-sha256", private: private, txt: "v=DKIM1; k=rsa; p=" <> Base.encode64(der)}
  end

  def ed25519_key do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      alg: "ed25519-sha256",
      private: private,
      txt: "v=DKIM1; k=ed25519; p=" <> Base.encode64(public)
    }
  end

  @doc "Publishes `key` under a fresh selector for `domain`; returns the selector."
  def publish(key, domain) do
    selector = "s#{System.unique_integer([:positive])}"
    DKIMTestResolver.put("#{selector}._domainkey.#{domain}", key.txt)
    selector
  end

  @doc """
  Prepends a DKIM-Signature to `raw` (a CRLF message as gen_smtp delivers it).

  Options: `:d` (required), `:s`, `:h`, `:c` (`{header, body}`), `:extra` tags.
  """
  def sign(raw, key, opts) do
    d = Keyword.fetch!(opts, :d)
    s = Keyword.get(opts, :s, "sel")
    h = Keyword.get(opts, :h, ["from", "subject", "date"])
    {hc, bc} = Keyword.get(opts, :c, {:relaxed, :relaxed})

    [head, body] = :binary.split(raw, "\r\n\r\n")
    body_hash = :crypto.hash(:sha256, body(body, bc)) |> Base.encode64()

    tags =
      ["v=1", "a=#{key.alg}", "c=#{hc}/#{bc}", "d=#{d}", "s=#{s}", "h=#{Enum.join(h, ":")}"] ++
        Keyword.get(opts, :extra, []) ++ ["bh=#{body_hash}", "b="]

    field = "DKIM-Signature: " <> Enum.join(tags, ";\r\n\t")
    headers = headers(head)

    data =
      Enum.map(select(h, headers), &header(&1, hc)) ++
        [String.replace_suffix(header(field, hc), "\r\n", "")]

    data = IO.iodata_to_binary(data)

    signature =
      case key.alg do
        "rsa-sha256" ->
          :public_key.sign(data, :sha256, key.private)

        "ed25519-sha256" ->
          :crypto.sign(:eddsa, :none, :crypto.hash(:sha256, data), [key.private, :ed25519])
      end

    field <> Base.encode64(signature) <> "\r\n" <> raw
  end

  defp headers(head) do
    head
    |> String.split("\r\n")
    |> Enum.chunk_while(
      nil,
      fn
        <<c, _::binary>> = line, acc when c in [?\s, ?\t] -> {:cont, acc <> "\r\n" <> line}
        line, nil -> {:cont, line}
        line, acc -> {:cont, acc, line}
      end,
      fn acc -> {:cont, acc, nil} end
    )
  end

  defp select(names, headers) do
    {picked, _} =
      Enum.reduce(names, {[], Enum.reverse(headers)}, fn name, {picked, remaining} ->
        idx = Enum.find_index(remaining, &(field_name(&1) == name))

        if idx,
          do: {picked ++ [Enum.at(remaining, idx)], List.delete_at(remaining, idx)},
          else: {picked, remaining}
      end)

    picked
  end

  defp field_name(field),
    do: field |> String.split(":", parts: 2) |> hd() |> String.trim() |> String.downcase()

  defp header(field, :simple), do: field <> "\r\n"

  defp header(field, :relaxed) do
    [name, value] = String.split(field, ":", parts: 2)
    words = value |> String.replace("\r\n", "") |> String.split([" ", "\t"], trim: true)
    String.downcase(String.trim(name)) <> ":" <> Enum.join(words, " ") <> "\r\n"
  end

  defp body(body, mode) do
    lines =
      body
      |> String.split("\r\n")
      |> Enum.map(fn line ->
        if mode == :relaxed,
          do: line |> String.replace(~r/[ \t]+/, " ") |> String.trim_trailing(" "),
          else: line
      end)
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()

    case {lines, mode} do
      {[], :relaxed} -> ""
      {[], :simple} -> "\r\n"
      _ -> Enum.join(lines, "\r\n") <> "\r\n"
    end
  end
end
