defmodule Pux.DKIM do
  @moduledoc """
  DKIM (RFC 6376) verification over the raw message bytes as gen_smtp hands them
  to `handle_DATA` (CRLF line endings, dot-unstuffed, final CRLF stripped).

  Supports rsa-sha256 and ed25519-sha256 (RFC 8463), simple and relaxed
  canonicalisation, `l=` (only when it covers the whole body) and `x=`.
  Keys come from `Pux.DKIMResolver` or `config :pux, :dkim, resolver: Module`.
  """

  @max_signatures 5
  @dns_timeout_ms 2_000
  @min_rsa_bits 1024
  @max_rsa_bits 8192

  @b_tag ~r/([;:]\s*b\s*=)[\sA-Za-z0-9+\/=]*/
  @dns_name ~r/\A[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\z/i

  @doc """
  True when some valid signature's `d=` aligns with `from_domain`: equal, or one
  is a subdomain of the other. Messages with more than one From header never align.

  Options: `:resolver`, `:timeout_ms` (DNS), `:now` (unix seconds, for `x=`).
  """
  @spec aligned?(binary(), String.t() | nil, keyword()) :: boolean()
  def aligned?(raw, from_domain, opts \\ [])
  def aligned?(_raw, nil, _opts), do: false

  def aligned?(raw, from_domain, opts) when is_binary(raw) do
    from_domain = String.downcase(from_domain)
    {headers, body} = split(raw)

    if Enum.count(headers, &(elem(&1, 0) == "from")) == 1 do
      headers
      |> Enum.flat_map(fn
        {"dkim-signature", field} ->
          case parse_signature(field) do
            {:ok, sig} -> if aligned_domain?(sig.d, from_domain), do: [sig], else: []
            :error -> []
          end

        _ ->
          []
      end)
      |> Enum.take(@max_signatures)
      |> Enum.any?(&valid?(&1, headers, body, opts))
    else
      false
    end
  end

  # No public suffix list: a d= that is a public suffix (e.g. co.in) would align
  # with every domain under it. Publishing a key there takes control of the
  # suffix's DNS, so we only reject bare TLDs.
  defp aligned_domain?(d, from) do
    String.contains?(d, ".") and
      (d == from or String.ends_with?(from, "." <> d) or String.ends_with?(d, "." <> from))
  end

  defp valid?(sig, headers, body, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)
    canonical_body = canon_body(body, sig.body_c)

    with true <- is_nil(sig.x) or sig.x >= now,
         true <- is_nil(sig.l) or sig.l == byte_size(canonical_body),
         true <- :crypto.hash(:sha256, canonical_body) == sig.bh,
         {:ok, key} <- fetch_key(sig, opts) do
      verify(sig.a, signed_data(sig, headers), sig.b, key)
    else
      _ -> false
    end
  end

  defp verify("rsa-sha256", data, signature, key) do
    :public_key.verify(data, :sha256, signature, key)
  rescue
    _ -> false
  end

  defp verify("ed25519-sha256", data, signature, {:ed25519, key}) do
    :crypto.verify(:eddsa, :none, :crypto.hash(:sha256, data), signature, [key, :ed25519])
  rescue
    _ -> false
  end

  defp signed_data(sig, headers) do
    pool = headers |> Enum.reverse() |> Enum.group_by(&elem(&1, 0))

    {selected, _} =
      Enum.flat_map_reduce(sig.h, pool, fn name, pool ->
        case Map.get(pool, name, []) do
          [header | rest] -> {[canon_header(header, sig.header_c)], Map.put(pool, name, rest)}
          [] -> {[], pool}
        end
      end)

    own =
      canon_header(
        {"dkim-signature", Regex.replace(@b_tag, sig.field, "\\1", global: false)},
        sig.header_c
      )

    IO.iodata_to_binary([selected, binary_part(own, 0, byte_size(own) - 2)])
  end

  ## Message parsing

  defp split(raw) do
    case :binary.split(raw, "\r\n\r\n") do
      [head, body] -> {parse_headers(head), body}
      [head] -> {parse_headers(head), ""}
    end
  end

  # [{lowercased name, raw field without the trailing CRLF}] in message order.
  defp parse_headers(head) do
    head
    |> :binary.split("\r\n", [:global])
    |> Enum.reduce([], fn
      "", acc ->
        acc

      <<c, _::binary>> = line, [{name, field} | rest] when c in [?\s, ?\t] ->
        [{name, field <> "\r\n" <> line} | rest]

      line, acc ->
        case :binary.split(line, ":") do
          [name, _] -> [{name |> String.trim_trailing() |> String.downcase(), line} | acc]
          _ -> acc
        end
    end)
    |> Enum.reverse()
  end

  defp parse_signature(field) do
    [_, value] = :binary.split(field, ":")

    with {:ok, tags} <- parse_tags(value),
         %{"v" => "1", "a" => a, "b" => b, "bh" => bh, "d" => d, "s" => s, "h" => h} <- tags,
         true <- a in ["rsa-sha256", "ed25519-sha256"],
         true <- d =~ @dns_name and s =~ @dns_name,
         {:ok, b} <- decode64(b),
         {:ok, bh} <- decode64(bh),
         {:ok, header_c, body_c} <- parse_canon(Map.get(tags, "c", "simple")),
         {:ok, l} <- optional_int(tags["l"]),
         {:ok, x} <- optional_int(tags["x"]),
         h = h |> String.split(":") |> Enum.map(&(&1 |> String.trim() |> String.downcase())),
         true <- "from" in h do
      {:ok,
       %{
         field: field,
         a: a,
         b: b,
         bh: bh,
         d: String.downcase(d),
         s: s,
         h: h,
         header_c: header_c,
         body_c: body_c,
         l: l,
         x: x
       }}
    else
      _ -> :error
    end
  end

  defp parse_tags(text) do
    text
    |> String.replace("\r\n", "")
    |> String.split(";")
    |> Enum.reduce_while({:ok, %{}}, fn part, {:ok, acc} ->
      case String.split(part, "=", parts: 2) do
        [name, value] ->
          name = String.trim(name)

          if Map.has_key?(acc, name),
            do: {:halt, :error},
            else: {:cont, {:ok, Map.put(acc, name, String.trim(value))}}

        [blank] ->
          if String.trim(blank) == "", do: {:cont, {:ok, acc}}, else: {:halt, :error}
      end
    end)
  end

  defp parse_canon(c) do
    case String.split(c, "/") do
      [h] -> canon_pair(h, "simple")
      [h, b] -> canon_pair(h, b)
      _ -> :error
    end
  end

  defp canon_pair(h, b) when h in ["simple", "relaxed"] and b in ["simple", "relaxed"],
    do: {:ok, String.to_atom(h), String.to_atom(b)}

  defp canon_pair(_, _), do: :error

  defp optional_int(nil), do: {:ok, nil}

  defp optional_int(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp decode64(value), do: value |> String.replace(~r/\s/, "") |> Base.decode64()

  ## Keys

  defp fetch_key(sig, opts) do
    resolver =
      Keyword.get_lazy(opts, :resolver, fn ->
        Application.get_env(:pux, :dkim, []) |> Keyword.get(:resolver, Pux.DKIMResolver)
      end)

    timeout = Keyword.get(opts, :timeout_ms, @dns_timeout_ms)

    case resolver.lookup_txt("#{sig.s}._domainkey.#{sig.d}", timeout) do
      {:ok, records} -> Enum.find_value(records, :error, &parse_key(&1, sig.a))
      _ -> :error
    end
  end

  defp parse_key(txt, alg) do
    with {:ok, tags} <- parse_tags(txt),
         true <- Map.get(tags, "v", "DKIM1") == "DKIM1",
         {:ok, der} when der != "" <- decode64(Map.get(tags, "p", "")),
         {:ok, key} <- decode_key(Map.get(tags, "k", "rsa"), alg, der) do
      {:ok, key}
    else
      _ -> nil
    end
  end

  defp decode_key("ed25519", "ed25519-sha256", <<_::binary-size(32)>> = key),
    do: {:ok, {:ed25519, key}}

  defp decode_key("rsa", "rsa-sha256", der) do
    key =
      try do
        :public_key.pem_entry_decode({:SubjectPublicKeyInfo, der, :not_encrypted})
      rescue
        _ -> :public_key.der_decode(:RSAPublicKey, der)
      end

    case key do
      {:RSAPublicKey, n, _e} when is_integer(n) ->
        bits = byte_size(:binary.encode_unsigned(n)) * 8
        if bits in @min_rsa_bits..@max_rsa_bits, do: {:ok, key}, else: :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp decode_key(_k, _alg, _der), do: :error

  ## Canonicalisation (RFC 6376 section 3.4)

  @doc false
  def canon_header({_name, field}, :simple), do: field <> "\r\n"

  def canon_header({name, field}, :relaxed) do
    [_, value] = :binary.split(field, ":")

    value =
      value
      |> String.replace("\r\n", "")
      |> String.replace(~r/[ \t]+/, " ")
      |> String.trim(" ")

    name <> ":" <> value <> "\r\n"
  end

  @doc false
  def canon_body(body, :simple) do
    case body |> ensure_crlf() |> trim_trailing_crlf() do
      "" -> "\r\n"
      body -> body <> "\r\n"
    end
  end

  def canon_body(body, :relaxed) do
    body
    |> ensure_crlf()
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(" \r\n", "\r\n")
    |> trim_trailing_crlf()
    |> case do
      "" -> ""
      body -> body <> "\r\n"
    end
  end

  defp ensure_crlf(""), do: ""

  defp ensure_crlf(body) do
    if String.ends_with?(body, "\r\n"), do: body, else: body <> "\r\n"
  end

  defp trim_trailing_crlf(body) do
    size = byte_size(body)

    if size >= 2 and binary_part(body, size - 2, 2) == "\r\n",
      do: trim_trailing_crlf(binary_part(body, 0, size - 2)),
      else: body
  end
end
