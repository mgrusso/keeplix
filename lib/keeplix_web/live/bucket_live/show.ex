defmodule KeeplixWeb.BucketLive.Show do
  use KeeplixWeb, :live_view

  alias Keeplix.{Accounts, Buckets, Storage}
  alias Keeplix.S3.Presign

  @page_size 50

  def mount(%{"name" => name}, session, socket) do
    mount_browser(name, "", session, socket)
  end

  defp mount_browser(name, prefix, session, socket) do
    user = get_user(session)
    bucket = Buckets.get_bucket(name)

    cond do
      bucket == nil ->
        {:ok, redirect_to_app(socket, user, :error, gettext("Bucket not found."))}

      not Buckets.can_read?(user, bucket) ->
        {:ok, redirect_to_app(socket, user, :error, gettext("Not authorized."))}

      true ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:bucket, bucket)
         |> assign(:prefix, prefix)
         |> assign(:query, "")
         |> assign(:sort_by, :key)
         |> assign(:sort_dir, :asc)
         |> assign(:page, 1)
         |> assign(:selected, MapSet.new())
         |> assign(:renaming, nil)
         |> assign(:copying, nil)
         |> assign(:copy_bulk, [])
         |> assign(:copy_targets, [])
         |> assign(:preview_key, nil)
         |> assign(:share, nil)
         |> assign(:share_expiry, 3_600)
         |> assign(:usage_bytes, usage_bytes(bucket))
         |> assign(:can_write, Buckets.can_write?(user, bucket))
         |> allow_upload(:files, accept: :any, max_entries: 20, max_file_size: 500_000_000)
         |> load_entries()}
    end
  end

  # The template requires @bucket/@streams/@uploads/... even when we
  # navigate away immediately, so stub them instead of crashing.
  defp redirect_to_app(socket, user, kind, message) do
    socket
    |> assign(:current_user, user)
    |> assign(:bucket, %{name: ""})
    |> assign(:prefix, "")
    |> assign(:query, "")
    |> assign(:sort_by, :key)
    |> assign(:sort_dir, :asc)
    |> assign(:page, 1)
    |> assign(:selected, MapSet.new())
    |> assign(:renaming, nil)
    |> assign(:copying, nil)
    |> assign(:copy_bulk, [])
    |> assign(:copy_targets, [])
    |> assign(:preview_key, nil)
    |> assign(:share, nil)
    |> assign(:share_expiry, 3_600)
    |> assign(:usage_bytes, 0)
    |> assign(:trash, [])
    |> assign(:multipart_uploads, [])
    |> assign(:total_entries, 0)
    |> assign(:pages, 1)
    |> assign(:page_keys, [])
    |> assign(:can_write, false)
    |> allow_upload(:files, accept: :any, max_entries: 20, max_file_size: 500_000_000)
    |> stream(:entries, [], reset: true)
    |> stream(:prefixes, [], reset: true)
    |> assign(:prefixes_list, [])
    |> put_flash(kind, message)
    |> push_navigate(to: "/app")
  end

  defp get_user(%{"user_id" => id}), do: Keeplix.Accounts.get_user(id)
  defp get_user(_), do: nil

  # Server-side authorization, re-checked against the database on every
  # event. Hiding buttons in the template is not sufficient.
  defp can_write?(socket) do
    case fresh_user(socket) do
      %Accounts.User{} = user -> Buckets.can_write?(user, socket.assigns.bucket)
      _ -> false
    end
  end

  defp fresh_user(socket) do
    case socket.assigns do
      %{current_user: %{id: uid}} ->
        case Accounts.get_user(uid) do
          %Accounts.User{is_active: true} = user -> user
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp load_entries(socket) do
    # Refresh the bucket row so the usage display tracks the ledger.
    bucket = Buckets.get_bucket(socket.assigns.bucket.name) || socket.assigns.bucket
    socket = assign(socket, :bucket, bucket)
    %{prefix: prefix, query: query} = socket.assigns

    {entries, prefixes} =
      if query != "" do
        # Substring search over the first 1000 keys (flat, case-insensitive).
        case Storage.list_objects(bucket.name, max_keys: 1000) do
          {:ok, %{entries: e}} ->
            needle = String.downcase(query)
            {Enum.filter(e, &String.contains?(String.downcase(&1.key), needle)), []}

          _ ->
            {[], []}
        end
      else
        case Storage.list_objects(bucket.name, prefix: prefix, delimiter: "/", max_keys: 1000) do
          {:ok, %{entries: e, prefixes: p}} -> {e, p}
          _ -> {[], []}
        end
      end

    entries = sort_entries(entries, socket.assigns.sort_by, socket.assigns.sort_dir)
    total = length(entries)
    pages = max(1, div(total + @page_size - 1, @page_size))
    page = socket.assigns.page |> max(1) |> min(pages)
    page_entries = Enum.slice(entries, (page - 1) * @page_size, @page_size)

    socket
    |> assign(:total_entries, total)
    |> assign(:usage_bytes, usage_bytes(bucket))
    |> assign(:trash, trash_entries(bucket))
    |> assign(:multipart_uploads, Storage.list_multipart_uploads(bucket.name))
    |> assign(:pages, pages)
    |> assign(:page, page)
    |> assign(:page_keys, Enum.map(page_entries, & &1.key))
    |> stream(:entries, page_entries, reset: true, dom_id: &"obj-#{Base.encode16(&1.key)}")
    |> stream(:prefixes, Enum.map(Enum.sort(prefixes), &%{id: &1}),
      reset: true,
      dom_id: &"px-#{Base.encode16(&1.id)}"
    )
    |> assign(:prefixes_list, prefixes)
  end

  defp sort_entries(entries, :size, :asc), do: Enum.sort_by(entries, & &1.size)
  defp sort_entries(entries, :size, :desc), do: Enum.sort_by(entries, & &1.size, :desc)
  defp sort_entries(entries, _key, :desc), do: Enum.sort_by(entries, & &1.key, :desc)
  defp sort_entries(entries, _key, _asc), do: Enum.sort_by(entries, & &1.key)

  def handle_params(params, _uri, socket) do
    prefix = Map.get(params, "prefix", "")

    socket =
      if prefix != socket.assigns.prefix do
        socket |> assign(:prefix, prefix) |> assign(:query, "") |> assign(:page, 1)
      else
        socket
      end

    {:noreply, load_entries(socket)}
  end

  def handle_event("navigate", %{"prefix" => prefix}, socket) do
    {:noreply,
     push_patch(socket, to: "/app/b/#{socket.assigns.bucket.name}?prefix=#{URI.encode(prefix)}")}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:query, String.trim(q)) |> assign(:page, 1) |> load_entries()}
  end

  def handle_event("sort", %{"by" => by}, socket) do
    by = if by == "size", do: :size, else: :key

    {by, dir} =
      if by == socket.assigns.sort_by, do: {by, flip(socket.assigns.sort_dir)}, else: {by, :asc}

    {:noreply, socket |> assign(:sort_by, by) |> assign(:sort_dir, dir) |> load_entries()}
  end

  def handle_event("page", %{"page" => raw}, socket) do
    page =
      case Integer.parse(to_string(raw)) do
        {n, ""} -> n
        _ -> 1
      end

    {:noreply, socket |> assign(:page, page) |> load_entries()}
  end

  def handle_event("toggle-select", %{"key" => key}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, key),
        do: MapSet.delete(selected, key),
        else: MapSet.put(selected, key)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select-page", _, socket) do
    page_keys = MapSet.new(socket.assigns.page_keys)
    selected = socket.assigns.selected

    selected =
      if MapSet.subset?(page_keys, selected),
        do: MapSet.difference(selected, page_keys),
        else: MapSet.union(selected, page_keys)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("clear-selected", _, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  def handle_event("delete", %{"key" => key}, socket) do
    if can_write?(socket) do
      bucket = socket.assigns.bucket
      Storage.delete_object(bucket.name, key)

      {:noreply,
       socket
       |> put_flash(:info, gettext("Deleted: %{key} (in trash, restorable)", key: key))
       |> load_entries()}
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("restore-object", %{"key" => key}, socket) do
    if can_write?(socket) do
      socket =
        case Storage.restore_object(socket.assigns.bucket.name, key) do
          :ok ->
            put_flash(socket, :info, "Restored: #{key}")

          {:error, :key_exists} ->
            put_flash(socket, :error, gettext("A live object already uses this key."))

          _ ->
            put_flash(socket, :error, gettext("Restore failed."))
        end

      {:noreply, load_entries(socket)}
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("purge-object", %{"key" => key}, socket) do
    if can_write?(socket) do
      Storage.purge_object(socket.assigns.bucket.name, key)

      {:noreply,
       socket
       |> put_flash(:info, gettext("Permanently deleted: %{key}", key: key))
       |> load_entries()}
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("empty-trash", _, socket) do
    if can_write?(socket) do
      {:ok, n} = Storage.empty_trash(socket.assigns.bucket.name)

      {:noreply,
       socket
       |> put_flash(:info, gettext("Trash emptied (%{n} object(s)).", n: n))
       |> load_entries()}
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("abort-upload", %{"id" => id}, socket) do
    if can_write?(socket) do
      Storage.abort_multipart(id)

      {:noreply,
       socket |> put_flash(:info, gettext("Multipart upload aborted.")) |> load_entries()}
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("delete-selected", _, socket) do
    if can_write?(socket) do
      bucket = socket.assigns.bucket
      keys = socket.assigns.selected |> MapSet.to_list()

      Enum.each(keys, fn key ->
        Storage.delete_object(bucket.name, key)
      end)

      {:noreply,
       socket
       |> assign(:selected, MapSet.new())
       |> put_flash(:info, gettext("%{n} object(s) moved to trash.", n: length(keys)))
       |> load_entries()}
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("rename-open", %{"key" => key}, socket) do
    if can_write?(socket) do
      {:noreply, assign(socket, :renaming, key)}
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("rename-cancel", _, socket) do
    {:noreply, assign(socket, :renaming, nil)}
  end

  def handle_event("rename-save", %{"key" => old_key, "name" => name}, socket) do
    if can_write?(socket) do
      bucket = socket.assigns.bucket.name
      new_base = name |> to_string() |> String.trim() |> String.replace("/", "")

      cond do
        new_base == "" ->
          {:noreply, put_flash(socket, :error, gettext("Name must not be empty."))}

        socket.assigns.prefix <> new_base == old_key ->
          {:noreply, assign(socket, :renaming, nil)}

        Storage.object_exists?(bucket, socket.assigns.prefix <> new_base) ->
          {:noreply, put_flash(socket, :error, gettext("Target already exists."))}

        true ->
          with %Buckets.Bucket{} = b <- Buckets.get_bucket(bucket),
               {:ok, %{size: size}} <- Storage.stat_object(bucket, old_key),
               :ok <- Buckets.quota_allows?(b, size),
               new_key = socket.assigns.prefix <> new_base,
               {:ok, _} <- Storage.rename_object(bucket, old_key, new_key) do
            {:noreply,
             socket
             |> assign(:renaming, nil)
             |> put_flash(:info, gettext("Renamed to %{name}.", name: new_base))
             |> load_entries()}
          else
            _ -> {:noreply, put_flash(socket, :error, gettext("Rename failed."))}
          end
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("copy-open", %{"key" => key}, socket) do
    if can_write?(socket) do
      targets =
        case fresh_user(socket) do
          nil -> []
          user -> user |> Buckets.visible_buckets() |> Enum.filter(&Buckets.can_write?(user, &1))
        end

      {:noreply, socket |> assign(:copying, key) |> assign(:copy_targets, targets)}
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("copy-cancel", _, socket) do
    {:noreply,
     socket |> assign(:copying, nil) |> assign(:copy_bulk, []) |> assign(:copy_targets, [])}
  end

  def handle_event("copy-selected-open", _, socket) do
    if can_write?(socket) do
      keys = socket.assigns.selected |> MapSet.to_list() |> Enum.sort()

      targets =
        case fresh_user(socket) do
          nil -> []
          user -> user |> Buckets.visible_buckets() |> Enum.filter(&Buckets.can_write?(user, &1))
        end

      if keys == [] do
        {:noreply, put_flash(socket, :error, gettext("Nothing selected."))}
      else
        {:noreply,
         socket
         |> assign(:copying, nil)
         |> assign(:copy_bulk, keys)
         |> assign(:copy_targets, targets)}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("copy-save", params, socket) do
    if can_write?(socket) do
      dest_bucket = Map.get(params, "dest_bucket", socket.assigns.bucket.name)
      move? = Map.get(params, "move") in ["true", "on", "1"]

      case socket.assigns.copy_bulk do
        [_ | _] = keys -> bulk_copy(socket, keys, dest_bucket, params, move?)
        _ -> single_copy(socket, socket.assigns.copying, dest_bucket, params, move?)
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("preview-open", %{"key" => key}, socket) do
    {:noreply, assign(socket, :preview_key, key)}
  end

  def handle_event("preview-close", _, socket) do
    {:noreply, assign(socket, :preview_key, nil)}
  end

  def handle_event("share", %{"key" => key}, socket) do
    %{bucket: bucket} = socket.assigns

    with %Accounts.User{} = user <- fresh_user(socket) || {:error, :auth},
         true <- Storage.object_exists?(bucket.name, key),
         {:ok, url} <-
           Presign.url(user, bucket.name, key, socket.assigns.share_expiry, Presign.base_url()) do
      {:noreply, assign(socket, :share, %{key: key, url: url})}
    else
      {:error, :no_active_key} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Sharing needs an active access key. Create one under Access keys."
         )}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not create share link."))}
    end
  end

  def handle_event("share-expiry", %{"seconds" => raw}, socket) do
    seconds =
      case Integer.parse(to_string(raw)) do
        {n, ""} when n in [3_600, 86_400, 604_800] -> n
        _ -> 3_600
      end

    socket = assign(socket, :share_expiry, seconds)

    # Regenerate an open link with the new lifetime.
    socket =
      case socket.assigns.share do
        %{key: key} ->
          %{bucket: bucket} = socket.assigns

          case fresh_user(socket) do
            %Accounts.User{} = user ->
              case Presign.url(user, bucket.name, key, seconds, Presign.base_url()) do
                {:ok, url} -> assign(socket, :share, %{key: key, url: url})
                _ -> socket
              end

            _ ->
              socket
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("share-close", _, socket) do
    {:noreply, assign(socket, :share, nil)}
  end

  def handle_event("upload", _params, socket) do
    if can_write?(socket) do
      bucket = socket.assigns.bucket.name
      prefix = socket.assigns.prefix

      total =
        socket.assigns.uploads.files.entries |> Enum.map(& &1.client_size) |> Enum.sum()

      case Buckets.get_bucket(bucket) do
        nil ->
          {:noreply, put_flash(socket, :error, gettext("Bucket not found."))}

        b ->
          case Buckets.quota_allows?(b, total) do
            :ok ->
              do_upload(socket, bucket, prefix)

            {:error, :quota_exceeded} ->
              {:noreply, put_flash(socket, :error, gettext("Bucket quota exceeded."))}
          end
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  defp do_upload(socket, bucket, prefix) do
    results =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        key = prefix <> entry.client_name

        case Storage.put_object_from_file(bucket, key, path, content_type: entry.client_type) do
          {:ok, _} -> {:ok, key}
          {:error, _} -> {:error, key}
        end
      end)

    {oks, fails} = Enum.split_with(results, &match?({:ok, _}, &1))

    {:noreply,
     socket
     |> put_flash(:info, upload_message(length(oks), length(fails)))
     |> load_entries()}
  end

  defp upload_message(ok, 0), do: gettext("%{n} file(s) uploaded.", n: ok)

  defp upload_message(ok, failed),
    do:
      gettext("%{ok} file(s) uploaded, %{failed} failed (size limit, quota, or content type).",
        ok: ok,
        failed: failed
      )

  # Splits "dir/sub/" into [{"dir", "dir/"}, {"sub", "dir/sub/"}]
  # so every ancestor folder is one click away.
  defp breadcrumb_segments(prefix) do
    prefix
    |> String.split("/", trim: true)
    |> Enum.scan("", fn seg, acc -> if acc == "", do: seg <> "/", else: acc <> seg <> "/" end)
    |> Enum.map(fn target ->
      label = target |> String.split("/", trim: true) |> List.last()
      {label, target}
    end)
  end

  defp format_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(nil), do: "—"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp usage_bytes(%Buckets.Bucket{} = bucket), do: Buckets.usage(bucket).bytes
  defp usage_bytes(_), do: 0

  defp trash_entries(bucket) do
    case Storage.list_trash(bucket.name) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp encode_key(key) do
    key
    |> String.split("/", trim: false)
    |> Enum.map_join("/", fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)
  end

  defp basename(key) do
    key |> String.split("/", trim: true) |> List.last() |> Kernel.||(key)
  end

  defp flip(:asc), do: :desc
  defp flip(:desc), do: :asc

  defp sort_label(:key, :asc), do: gettext("Name ↑")
  defp sort_label(:key, :desc), do: gettext("Name ↓")
  defp sort_label(:size, :asc), do: gettext("Size ↑")
  defp sort_label(:size, :desc), do: gettext("Size ↓")

  defp single_copy(socket, src_key, dest_bucket, params, move?) do
    dest_key = params |> Map.get("dest_key", src_key) |> to_string() |> String.trim()

    with true <- is_binary(src_key) and src_key != "",
         true <- dest_key != "",
         %Buckets.Bucket{} = dest <- Buckets.get_bucket(dest_bucket) || {:error, :missing},
         %Accounts.User{} = user <- fresh_user(socket) || {:error, :auth},
         true <- Buckets.can_write?(user, dest),
         {:ok, %{size: size}} <- Storage.stat_object(socket.assigns.bucket.name, src_key),
         :ok <- Buckets.quota_allows?(dest, size),
         {:ok, _} <-
           Storage.copy_object(dest_bucket, dest_key, socket.assigns.bucket.name, src_key) do
      if move?, do: Storage.delete_object(socket.assigns.bucket.name, src_key)

      {:noreply,
       socket
       |> assign(:copying, nil)
       |> assign(:copy_bulk, [])
       |> assign(:copy_targets, [])
       |> put_flash(
         :info,
         if(move?,
           do: gettext("Moved to %{dest}.", dest: dest_key),
           else: gettext("Copied to %{dest}.", dest: dest_key)
         )
       )
       |> load_entries()}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("Copy failed. Check target and permissions."))}
    end
  end

  defp bulk_copy(socket, keys, dest_bucket, params, move?) do
    src_bucket = socket.assigns.bucket.name

    prefix =
      params
      |> Map.get("dest_key", "")
      |> to_string()
      |> String.trim()
      |> String.trim_trailing("/")

    with %Buckets.Bucket{} = dest <- Buckets.get_bucket(dest_bucket) || {:error, :missing},
         %Accounts.User{} = user <- fresh_user(socket) || {:error, :auth},
         true <- Buckets.can_write?(user, dest),
         sizes when is_list(sizes) <- Enum.map(keys, &bulk_size(src_bucket, &1)),
         true <- Enum.all?(sizes, &match?({:ok, _}, &1)),
         total = Enum.sum(Enum.map(sizes, fn {:ok, s} -> s end)),
         :ok <- Buckets.quota_allows?(dest, total) do
      {done, failed} =
        Enum.reduce(keys, {[], []}, fn key, {ok_acc, fail_acc} ->
          dest_key = if prefix == "", do: basename(key), else: prefix <> "/" <> basename(key)

          case Storage.copy_object(dest_bucket, dest_key, src_bucket, key) do
            {:ok, _} ->
              if move?, do: Storage.delete_object(src_bucket, key)
              {[key | ok_acc], fail_acc}

            _ ->
              {ok_acc, [key | fail_acc]}
          end
        end)

      socket =
        socket
        |> assign(:copying, nil)
        |> assign(:copy_bulk, [])
        |> assign(:copy_targets, [])
        |> assign(:selected, MapSet.new())
        |> load_entries()

      if failed == [] do
        {:noreply,
         put_flash(
           socket,
           :info,
           if(move?,
             do: gettext("%{n} object(s) moved.", n: length(done)),
             else: gettext("%{n} object(s) copied.", n: length(done))
           )
         )}
      else
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("%{done} copied, %{failed} failed: %{keys}",
             done: length(done),
             failed: length(failed),
             keys: failed |> Enum.sort() |> Enum.join(", ")
           )
         )}
      end
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("Copy failed. Check target and permissions."))}
    end
  end

  defp bulk_size(bucket, key) do
    case Storage.stat_object(bucket, key) do
      {:ok, %{size: size}} -> {:ok, size}
      _ -> :error
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <nav
        aria-label="Breadcrumb"
        class="mb-4 flex flex-wrap items-center gap-1.5 text-sm font-medium"
      >
        <.link
          navigate="/app"
          class="rounded-lg px-2 py-1 text-slate-700 dark:text-slate-300 hover:bg-slate-200 dark:hover:bg-slate-700 hover:text-slate-900 dark:hover:text-white"
        >← Buckets</.link>
        <span aria-hidden="true" class="text-slate-400">/</span>
        <%= if @prefix == "" and @query == "" do %>
          <span
            aria-current="page"
            class="rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-2 py-1 font-mono font-bold text-slate-900 dark:text-slate-100"
          >{@bucket.name}</span>
        <% else %>
          <.link
            patch={"/app/b/#{@bucket.name}"}
            class="rounded-lg px-2 py-1 font-mono font-bold text-slate-700 dark:text-slate-300 hover:bg-slate-200 dark:hover:bg-slate-700 hover:text-slate-900 dark:hover:text-white"
          >{@bucket.name}</.link>
          <%= for {label, target} <- breadcrumb_segments(@prefix) do %>
            <span aria-hidden="true" class="text-slate-400">/</span>
            <%= if target == @prefix and @query == "" do %>
              <span
                aria-current="page"
                class="rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-2 py-1 font-mono font-bold text-slate-900 dark:text-slate-100"
              >{label}</span>
            <% else %>
              <.link
                patch={"/app/b/#{@bucket.name}?prefix=#{URI.encode_www_form(target)}"}
                class="rounded-lg px-2 py-1 font-mono font-semibold text-slate-700 dark:text-slate-300 hover:bg-slate-200 dark:hover:bg-slate-700 hover:text-slate-900 dark:hover:text-white"
              >{label}</.link>
            <% end %>
          <% end %>
        <% end %>
        <span class="ml-auto text-xs font-semibold text-slate-600 dark:text-slate-400">
          {gettext("%{usage} used · %{n} objects",
            usage: format_bytes(@usage_bytes),
            n: @total_entries
          )}
        </span>
      </nav>

      <div class="grid gap-5 lg:grid-cols-5">
        <section class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm lg:col-span-3">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">{gettext("Objects")}</h2>
            <form
              phx-submit="search"
              phx-change="search"
              id="search-form"
              phx-hook=".BrowserKeys"
              class="ml-auto flex gap-2"
            >
              <input
                type="search"
                name="q"
                id="search-input"
                value={@query}
                placeholder={gettext("Search objects…")}
                phx-debounce="400"
                class="h-9 w-52 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-3 text-sm text-slate-900 dark:text-slate-100 placeholder:text-slate-500 dark:placeholder:text-slate-400"
              />
              <script :type={Phoenix.LiveView.ColocatedHook} name=".BrowserKeys">
                export default {
                  mounted() {
                    this.handler = (e) => {
                      const active = document.activeElement;
                      const typing = active && /^(INPUT|TEXTAREA|SELECT)$/.test(active.tagName);
                      if (e.key === "/" && !typing) {
                        e.preventDefault();
                        document.getElementById("search-input")?.focus();
                      } else if (e.key === "Escape" && typing) {
                        active.blur();
                      }
                    };
                    document.addEventListener("keydown", this.handler);
                  },
                  destroyed() {
                    document.removeEventListener("keydown", this.handler);
                  }
                }
              </script>
            </form>
          </div>

          <div class="mt-3 flex flex-wrap items-center gap-2 text-sm">
            <button
              phx-click="sort"
              phx-value-by="key"
              class="rounded-lg border border-slate-300 dark:border-slate-700 px-2.5 py-1.5 font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
            >{if @sort_by == :key, do: sort_label(:key, @sort_dir), else: gettext("Name")}</button>
            <button
              phx-click="sort"
              phx-value-by="size"
              class="rounded-lg border border-slate-300 dark:border-slate-700 px-2.5 py-1.5 font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
            >{if @sort_by == :size, do: sort_label(:size, @sort_dir), else: gettext("Size")}</button>
            <span class="ml-auto font-medium text-slate-700 dark:text-slate-300">
              {gettext("Page %{page} of %{pages} · %{n} objects",
                page: @page,
                pages: @pages,
                n: @total_entries
              )}
            </span>
          </div>

          <%= if @query == "" do %>
            <h2 class="mt-5 text-lg font-bold text-slate-900 dark:text-slate-100">
              {gettext("Folders")}
            </h2>
            <div id="prefixes" phx-update="stream" class="mt-3 space-y-2">
              <div
                id="no-prefixes"
                class="hidden only:block rounded-lg bg-slate-50 dark:bg-slate-800 p-4 text-sm font-medium text-slate-700 dark:text-slate-300"
              >
                {gettext("No subfolders.")}
              </div>
              <div :for={{id, p} <- @streams.prefixes} id={id}>
                <button
                  phx-click="navigate"
                  phx-value-prefix={p.id}
                  class="flex w-full items-center gap-2 rounded-lg border border-slate-200 dark:border-slate-700 px-3 py-2.5 text-left font-mono text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
                >
                  <.icon name="hero-folder" class="size-5 text-slate-700 dark:text-slate-300" /> {p.id}
                </button>
              </div>
            </div>
          <% end %>

          <%= if MapSet.size(@selected) > 0 do %>
            <div class="mt-4 flex flex-wrap items-center gap-2 rounded-lg bg-slate-900 p-3 text-sm text-white">
              <span class="font-semibold">{gettext("%{n} selected", n: MapSet.size(@selected))}</span>
              <button
                phx-click="delete-selected"
                data-confirm={gettext("Delete all selected objects?")}
                class="rounded-lg bg-red-600 px-3 py-1.5 font-semibold hover:bg-red-500"
              >{gettext("Delete selected")}</button>
              <%= if @can_write do %>
                <button
                  phx-click="copy-selected-open"
                  class="rounded-lg bg-slate-700 px-3 py-1.5 font-semibold hover:bg-slate-600"
                >{gettext("Copy / move")}</button>
              <% end %>
              <button
                phx-click="clear-selected"
                class="rounded-lg px-3 py-1.5 font-semibold hover:bg-slate-700"
              >{gettext("Clear")}</button>
            </div>
          <% end %>

          <div id="entries" phx-update="stream" class="mt-3 space-y-2">
            <div
              id="no-entries"
              class="hidden only:block rounded-lg bg-slate-50 dark:bg-slate-800 p-4 text-sm font-medium text-slate-700 dark:text-slate-300"
            >
              {if @query == "",
                do: gettext("This folder is empty."),
                else: gettext("No objects match this filter.")}
            </div>
            <div
              :for={{id, e} <- @streams.entries}
              id={id}
              class="space-y-2 rounded-lg border border-slate-200 dark:border-slate-700 px-3 py-2.5"
            >
              <div class="flex min-w-0 items-center gap-2">
                <%= if @can_write do %>
                  <input
                    type="checkbox"
                    phx-click="toggle-select"
                    phx-value-key={e.key}
                    checked={MapSet.member?(@selected, e.key)}
                    aria-label={gettext("Select %{key}", key: e.key)}
                    class="size-4 shrink-0 rounded border-slate-300 dark:border-slate-700"
                  />
                <% end %>
                <.icon
                  name="hero-document"
                  class="size-5 shrink-0 text-slate-500 dark:text-slate-400"
                />
                <span
                  title={e.key}
                  class="min-w-0 flex-1 truncate font-mono text-sm font-bold text-slate-900 dark:text-slate-100"
                >{basename(e.key)}</span>
                <span class="shrink-0 rounded bg-slate-100 dark:bg-slate-800 px-2 py-0.5 text-xs font-bold text-slate-800 dark:text-slate-200">{format_size(
                  e.size
                )}</span>
              </div>
              <%= if basename(e.key) != e.key do %>
                <div
                  class="truncate pl-7 font-mono text-xs text-slate-500 dark:text-slate-400"
                  title={e.key}
                >
                  {e.key}
                </div>
              <% end %>
              <%= if @renaming == e.key do %>
                <form phx-submit="rename-save" class="flex w-full items-center gap-2 pl-7">
                  <input type="hidden" name="key" value={e.key} />
                  <input
                    type="text"
                    name="name"
                    value={basename(e.key)}
                    aria-label={gettext("New name")}
                    class="h-9 min-w-0 flex-1 rounded-lg border border-slate-300 dark:border-slate-700 px-2 font-mono text-sm"
                  />
                  <button class="h-9 shrink-0 rounded-lg bg-slate-900 px-3 text-sm font-semibold text-white dark:bg-slate-100 dark:text-slate-900">{gettext(
                    "Save"
                  )}</button>
                  <button
                    type="button"
                    phx-click="rename-cancel"
                    class="h-9 shrink-0 rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm font-semibold"
                  >{gettext("Cancel")}</button>
                </form>
              <% else %>
                <div class="flex flex-wrap gap-2 pl-7">
                  <button
                    phx-click="preview-open"
                    phx-value-key={e.key}
                    class="inline-flex h-9 items-center rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
                  >{gettext("Preview")}</button>
                  <a
                    href={"/files/#{@bucket.name}/#{encode_key(e.key)}"}
                    class="inline-flex h-9 items-center rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
                  >{gettext("Download")}</a>
                  <%= if @can_write do %>
                    <button
                      phx-click="share"
                      phx-value-key={e.key}
                      class="inline-flex h-9 items-center rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
                    >{gettext("Share")}</button>
                    <button
                      phx-click="rename-open"
                      phx-value-key={e.key}
                      class="inline-flex h-9 items-center rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
                    >{gettext("Rename")}</button>
                    <button
                      phx-click="copy-open"
                      phx-value-key={e.key}
                      class="inline-flex h-9 items-center rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
                    >{gettext("Copy")}</button>
                    <button
                      phx-click="delete"
                      phx-value-key={e.key}
                      data-confirm={gettext("Really delete?")}
                      class="inline-flex h-9 items-center rounded-lg border border-red-300 dark:border-red-800 px-3 text-sm font-semibold text-red-700 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950"
                    >{gettext("Delete")}</button>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <div class="mt-4 flex items-center justify-between text-sm">
            <button
              phx-click="page"
              phx-value-page={@page - 1}
              disabled={@page <= 1}
              class="rounded-lg border border-slate-300 dark:border-slate-700 px-3 py-1.5 font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800 disabled:opacity-40"
            >← Prev</button>
            <span class="font-medium text-slate-700 dark:text-slate-300">{gettext(
              "Page %{page} of %{pages}",
              page: @page,
              pages: @pages
            )}</span>
            <button
              phx-click="page"
              phx-value-page={@page + 1}
              disabled={@page >= @pages}
              class="rounded-lg border border-slate-300 dark:border-slate-700 px-3 py-1.5 font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800 disabled:opacity-40"
            >Next →</button>
          </div>

          <div class="mt-2 text-xs font-medium text-slate-600 dark:text-slate-400">
            <button
              phx-click="select-page"
              class="underline hover:text-slate-900 dark:hover:text-white"
            >{gettext("Toggle this page")}</button>
          </div>
        </section>

        <aside class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm lg:col-span-2">
          <%= if @can_write do %>
            <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">{gettext("Upload")}</h2>
            <p class="mt-1 text-sm text-slate-700 dark:text-slate-300">
              {gettext("Files are uploaded to the current folder")} <code class="rounded bg-slate-100 dark:bg-slate-800 px-1 font-mono text-slate-900 dark:text-slate-100">{if @prefix == "", do: "/", else: @prefix}</code>.
            </p>
            <form
              phx-submit="upload"
              phx-change="validate"
              phx-drop-target={@uploads.files.ref}
              id="upload-form"
              class="mt-4 space-y-3 rounded-xl border-2 border-dashed border-slate-300 dark:border-slate-700 p-4"
            >
              <.live_file_input
                upload={@uploads.files}
                class="w-full text-sm text-slate-800 dark:text-slate-200"
              />
              <p class="text-xs font-medium text-slate-600 dark:text-slate-400">
                {gettext("…or drop files here (up to 20 at once).")}
              </p>
              <%= for entry <- @uploads.files.entries do %>
                <div class="text-xs font-semibold text-slate-800 dark:text-slate-200">
                  <div class="flex justify-between gap-2">
                    <span class="truncate font-mono">{entry.client_name}</span>
                    <span>{entry.progress}%</span>
                  </div>
                  <div class="mt-1 h-1.5 overflow-hidden rounded-full bg-slate-200 dark:bg-slate-700">
                    <div
                      class="h-full rounded-full bg-slate-900 dark:bg-slate-100"
                      style={"width: #{entry.progress}%"}
                    >
                    </div>
                  </div>
                </div>
              <% end %>
              <button class="h-10 w-full rounded-lg bg-slate-900 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">{gettext(
                "Upload"
              )}</button>
            </form>
          <% else %>
            <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">{gettext("Note")}</h2>
            <p class="mt-1 text-sm text-slate-700 dark:text-slate-300">
              {gettext("You have read-only access to this bucket.")}
            </p>
          <% end %>
          <%= if @trash != [] do %>
            <h2 class="mt-6 text-lg font-bold text-slate-900 dark:text-slate-100">
              {gettext("Trash")}
            </h2>
            <p class="mt-1 text-sm text-slate-700 dark:text-slate-300">
              {gettext("Deleted objects stay restorable until purged.")}
            </p>
            <ul id="trash-list" class="mt-3 space-y-2">
              <%= for t <- @trash do %>
                <li
                  id={"trash-#{Base.encode16(t.key)}"}
                  class="flex items-center gap-2 rounded-lg border border-slate-300 dark:border-slate-700 px-3 py-2 text-sm"
                >
                  <span class="min-w-0 flex-1 truncate font-mono text-slate-900 dark:text-slate-100">{t.key}</span>
                  <%= if @can_write do %>
                    <button
                      phx-click="restore-object"
                      phx-value-key={t.key}
                      class="rounded-lg border border-slate-300 dark:border-slate-700 px-2.5 py-1 text-xs font-semibold hover:bg-slate-100 dark:hover:bg-slate-800"
                    >{gettext("Restore")}</button>
                    <button
                      phx-click="purge-object"
                      phx-value-key={t.key}
                      data-confirm={gettext("Permanently delete this object?")}
                      class="rounded-lg border border-red-300 dark:border-red-700 px-2.5 py-1 text-xs font-semibold text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950"
                    >{gettext("Delete")}</button>
                  <% end %>
                </li>
              <% end %>
            </ul>
            <%= if @can_write do %>
              <button
                phx-click="empty-trash"
                data-confirm={gettext("Permanently delete everything in trash?")}
                class="mt-3 rounded-lg border border-red-300 dark:border-red-700 px-3 py-1.5 text-xs font-semibold text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950"
              >{gettext("Empty trash")}</button>
            <% end %>
          <% end %>
          <%= if @can_write and @multipart_uploads != [] do %>
            <h2 class="mt-6 text-lg font-bold text-slate-900 dark:text-slate-100">
              Multipart uploads
            </h2>
            <p class="mt-1 text-sm text-slate-700 dark:text-slate-300">
              {gettext("Unfinished uploads still occupy space until completed or aborted.")}
            </p>
            <ul id="multipart-uploads" class="mt-3 space-y-2">
              <%= for u <- @multipart_uploads do %>
                <li
                  id={"multipart-#{u.upload_id}"}
                  class="flex items-center gap-2 rounded-lg border border-slate-300 dark:border-slate-700 px-3 py-2 text-sm"
                >
                  <span class="min-w-0 flex-1 truncate font-mono text-slate-900 dark:text-slate-100">{u.key}</span>
                  <button
                    phx-click="abort-upload"
                    phx-value-id={u.upload_id}
                    data-confirm={gettext("Abort this multipart upload?")}
                    class="rounded-lg border border-red-300 dark:border-red-700 px-2.5 py-1 text-xs font-semibold text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950"
                  >{gettext("Abort")}</button>
                </li>
              <% end %>
            </ul>
          <% end %>
        </aside>
      </div>

      <%= if @preview_key do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/60 p-4">
          <div class="w-full max-w-3xl overflow-hidden rounded-xl bg-white dark:bg-slate-900 shadow-xl">
            <div class="flex items-center gap-2 border-b border-slate-200 dark:border-slate-700 px-4 py-3">
              <span class="min-w-0 flex-1 truncate font-mono text-sm font-bold text-slate-900 dark:text-slate-100">{@preview_key}</span>
              <a
                href={"/files/#{@bucket.name}/#{encode_key(@preview_key)}"}
                class="rounded-lg border border-slate-300 dark:border-slate-700 px-3 py-1.5 text-sm font-semibold hover:bg-slate-100 dark:hover:bg-slate-800"
              >{gettext("Download")}</a>
              <button
                phx-click="preview-close"
                class="rounded-lg border border-slate-300 dark:border-slate-700 px-3 py-1.5 text-sm font-semibold hover:bg-slate-100 dark:hover:bg-slate-800"
              >{gettext("Close")}</button>
            </div>
            <iframe
              src={"/files/#{@bucket.name}/#{encode_key(@preview_key)}?preview=1"}
              sandbox=""
              title={gettext("File preview")}
              class="h-[70vh] w-full bg-white"
            ></iframe>
          </div>
        </div>
      <% end %>

      <%= if @copying || @copy_bulk != [] do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/60 p-4">
          <div class="w-full max-w-md rounded-xl bg-white dark:bg-slate-900 p-5 shadow-xl">
            <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">
              {gettext("Copy / move")}
            </h2>
            <%= if @copy_bulk == [] do %>
              <p class="mt-1 truncate font-mono text-sm text-slate-700 dark:text-slate-300">
                {@copying}
              </p>
            <% else %>
              <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
                {gettext("%{n} object(s) — basenames are kept, pick a target folder:",
                  n: length(@copy_bulk)
                )}
              </p>
            <% end %>
            <form phx-submit="copy-save" class="mt-4 space-y-3">
              <div>
                <label
                  for="copy-bucket"
                  class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
                >{gettext("Target bucket")}</label>
                <select
                  id="copy-bucket"
                  name="dest_bucket"
                  class="h-10 w-full rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-2 text-sm"
                >
                  <%= for b <- @copy_targets do %>
                    <option value={b.name} selected={b.name == @bucket.name}>{b.name}</option>
                  <% end %>
                </select>
              </div>
              <div>
                <label
                  for="copy-key"
                  class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
                >{if @copy_bulk == [],
                  do: gettext("Target key"),
                  else: gettext("Target folder prefix (empty = same folder)")}</label>
                <input
                  id="copy-key"
                  type="text"
                  name="dest_key"
                  value={if @copy_bulk == [], do: @copying, else: ""}
                  class="h-10 w-full rounded-lg border border-slate-300 dark:border-slate-700 px-3 font-mono text-sm"
                />
              </div>
              <label class="flex items-center gap-2 text-sm font-medium text-slate-800 dark:text-slate-200">
                <input
                  type="checkbox"
                  name="move"
                  value="true"
                  class="size-4 rounded border-slate-300 dark:border-slate-700"
                /> {gettext("Delete source (move instead of copy)")}
              </label>
              <div class="flex gap-2">
                <button class="h-10 flex-1 rounded-lg bg-slate-900 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">{gettext(
                  "Copy"
                )}</button>
                <button
                  type="button"
                  phx-click="copy-cancel"
                  class="h-10 rounded-lg border border-slate-300 dark:border-slate-700 px-4 text-sm font-semibold"
                >{gettext("Cancel")}</button>
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <%= if @share do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/60 p-4">
          <div class="w-full max-w-xl rounded-xl bg-white dark:bg-slate-900 p-5 shadow-xl">
            <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">
              {gettext("Share link")}
            </h2>
            <p class="mt-1 truncate font-mono text-sm text-slate-700 dark:text-slate-300">
              {@share.key}
            </p>
            <p class="mt-1 text-xs font-medium text-slate-600 dark:text-slate-400">
              {gettext(
                "Anyone with this link can download the file until it expires. Revoking your access keys kills the link."
              )}
            </p>
            <div class="mt-3 flex gap-2 text-sm">
              <%= for {label, secs} <- [{gettext("1 hour"), 3_600}, {gettext("1 day"), 86_400}, {gettext("7 days"), 604_800}] do %>
                <button
                  phx-click="share-expiry"
                  phx-value-seconds={secs}
                  class={[
                    "rounded-lg border px-3 py-1.5 font-semibold",
                    if(@share_expiry == secs,
                      do:
                        "border-slate-900 bg-slate-900 text-white dark:border-slate-100 dark:bg-slate-100 dark:text-slate-900",
                      else:
                        "border-slate-300 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800"
                    )
                  ]}
                >{label}</button>
              <% end %>
            </div>
            <code
              phx-no-curly-interpolation
              class="mt-3 block break-all rounded-lg bg-slate-100 dark:bg-slate-800 p-3 font-mono text-xs text-slate-900 dark:text-slate-100"
            >{@share.url}</code>
            <div class="mt-3 flex justify-end gap-2">
              <button
                type="button"
                id="share-copy"
                phx-hook=".CopyButton"
                data-copy={@share.url}
                class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300"
              >{gettext("Copy")}</button>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyButton">
                export default {
                  mounted() {
                    const fallback = () => {
                      const ta = document.createElement("textarea");
                      ta.value = this.el.dataset.copy || "";
                      document.body.appendChild(ta);
                      ta.select();
                      try { document.execCommand("copy"); done(); } catch (_e) { /* ignore */ }
                      document.body.removeChild(ta);
                    };
                    const done = () => {
                      const orig = this.el.textContent;
                      this.el.textContent = "Copied!";
                      setTimeout(() => { this.el.textContent = orig; }, 1200);
                    };
                    this.el.addEventListener("click", () => {
                      if (navigator.clipboard && window.isSecureContext) {
                        navigator.clipboard.writeText(this.el.dataset.copy || "").then(done, fallback);
                      } else {
                        fallback();
                      }
                    });
                  }
                }
              </script>
              <button
                phx-click="share-close"
                class="h-10 rounded-lg border border-slate-300 dark:border-slate-700 px-4 text-sm font-semibold"
              >{gettext("Close")}</button>
            </div>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
