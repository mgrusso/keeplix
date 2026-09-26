defmodule Keeplix.DelimiterPaginationTest do
  @moduledoc """
  Delimiter pagination must never swallow keys (audit F4): contents and
  prefixes share the max_keys budget, truncation reflects remaining rows.
  """
  use Keeplix.DataCase

  alias Keeplix.{Accounts, Buckets, Storage}

  setup do
    {:ok, owner} =
      Accounts.create_user(%{
        username: "pg-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "pg-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    {:ok, bucket: bucket}
  end

  defp walk(bucket, max_keys, delimiter) do
    Stream.unfold(nil, fn
      :done ->
        nil

      token ->
        opts =
          [prefix: "", max_keys: max_keys, continuation_token: token] ++
            if(delimiter, do: [delimiter: delimiter], else: [])

        {:ok, page} = Storage.list_objects(bucket, opts)
        next = if page.truncated, do: page.next_token, else: :done
        {{page.entries, page.prefixes, page.truncated}, next}
    end)
    |> Enum.to_list()
  end

  test "wide prefix does not hide later keys", %{bucket: bucket} do
    for n <- 0..1004 do
      :ok = Storage.put_object(bucket, "fotos/#{pad(n)}.txt", "x") |> elem(0)
    end

    for f <- ~w(a.txt b.txt c.txt d.txt e.txt f.txt g.txt h.txt i.txt j.txt) do
      :ok = Storage.put_object(bucket, f, "x") |> elem(0)
    end

    :ok = Storage.put_object(bucket, "docs/a.txt", "x") |> elem(0)
    :ok = Storage.put_object(bucket, "docs/b.txt", "x") |> elem(0)
    :ok = Storage.put_object(bucket, "zebra.txt", "x") |> elem(0)

    pages = walk(bucket, 4, "/")
    assert length(pages) > 1

    {entries, prefixes, flags} =
      Enum.reduce(pages, {[], [], []}, fn {e, p, t}, {ae, ap, at} ->
        {ae ++ e, ap ++ p, at ++ [t]}
      end)

    keys = Enum.map(entries, & &1.key)
    assert "zebra.txt" in keys
    assert Enum.count(keys, &(&1 == "zebra.txt")) == 1

    for f <- ~w(a.txt b.txt c.txt d.txt e.txt f.txt g.txt h.txt i.txt j.txt) do
      assert f in keys
    end

    # Each prefix exactly once, no content loss, budget respected.
    assert Enum.sort(prefixes) == ["docs/", "fotos/"]
    assert length(keys) == 11

    for {e, p, _} <- pages, length(e) + length(p) > 0 do
      assert length(e) + length(p) <= 4
    end

    # All but the last page are truncated.
    assert List.last(flags) == false
    assert Enum.all?(Enum.drop(flags, -1), &(&1 == true))
  end

  test "plain listing paginates unchanged", %{bucket: bucket} do
    for n <- 1..7 do
      :ok = Storage.put_object(bucket, "k#{n}", "x") |> elem(0)
    end

    pages = walk(bucket, 3, nil)
    keys = pages |> Enum.flat_map(fn {e, _, _} -> Enum.map(e, & &1.key) end)
    assert keys == ~w(k1 k2 k3 k4 k5 k6 k7)
    assert length(pages) == 3
  end

  defp pad(n), do: n |> to_string() |> String.pad_leading(4, "0")
end
