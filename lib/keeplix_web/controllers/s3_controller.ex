defmodule KeeplixWeb.S3Controller do
  @moduledoc """
  S3-kompatible API (Pfad-Stil): `/:bucket/*key`.

  Authentifizierung: AWS Signature V4 (Header oder Presigned URL).
  """
  use KeeplixWeb, :controller

  alias Keeplix.{Accounts, Buckets, Storage}
  alias Keeplix.S3.{Auth, Xml}
  alias Keeplix.Buckets.Bucket

  # ---------- Service: GET / ----------

  @spec service(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def service(conn, params) do
    if Auth.s3_request?(conn) or Map.has_key?(params, "X-Amz-Algorithm") do
      list_buckets(conn, params)
    else
      # Normale Web-Anfrage -> Startseite
      redirect(conn, to: "/app")
    end
  end

  defp list_buckets(conn, _params) do
    with {:ok, user, key} <- Auth.verify(conn) do
      Accounts.touch_key_used(key)
      buckets = Buckets.visible_buckets(user)

      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, Xml.list_buckets(buckets, user.username))
    else
      {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  end

  # CORS-Preflight: Browser senden OPTIONS ohne Signatur. Mit passender
  # Regel antworten wir 200 + Allow-Header, sonst 403 wie S3 ohne Config.
  @spec cors_preflight(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cors_preflight(conn, %{"bucket" => bucket}) do
    origin = conn |> get_req_header("origin") |> List.first()

    method =
      conn |> get_req_header("access-control-request-method") |> List.first() |> to_string()

    case Buckets.cors_allowed?(bucket, origin, method) do
      {:ok, rule, allowed_origin} ->
        headers = rule["allowed_headers"] || []

        conn =
          conn
          |> put_resp_header("access-control-allow-origin", allowed_origin)
          |> put_resp_header(
            "access-control-allow-methods",
            Enum.join(rule["allowed_methods"] || [], ", ")
          )
          |> put_resp_header("vary", "Origin")

        conn =
          if headers == [] do
            conn
          else
            put_resp_header(conn, "access-control-allow-headers", Enum.join(headers, ", "))
          end

        conn =
          if rule["max_age"] do
            put_resp_header(conn, "access-control-max-age", to_string(rule["max_age"]))
          else
            conn
          end

        send_resp(conn, 200, "")

      :deny ->
        s3_error(conn, 403, "AccessDenied", "CORS configuration missing")
    end
  end

  def cors_preflight(conn, _params) do
    s3_error(conn, 403, "AccessDenied", "CORS configuration missing")
  end

  # ---------- Bucket ----------

  # Operations we deliberately do not implement (yet). Answered explicitly
  # so SDKs get a proper S3 error instead of confusing fallthroughs.
  @unimplemented_bucket_ops ~w(policy requestPayment website
    logging notification accelerate replication object-lock publicAccessBlock
    ownershipControls analytics inventory metrics request-payment intent)
  @unimplemented_object_ops ~w(torrent attributes legal-hold retention select)

  @spec bucket(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def bucket(conn, %{"bucket" => bucket} = params) do
    cond do
      op = unimplemented_param(params, @unimplemented_bucket_ops) ->
        not_implemented(conn, op)

      Map.has_key?(params, "versioning") and conn.method in ["PUT", "GET"] ->
        bucket_versioning(conn, bucket)

      Map.has_key?(params, "tagging") and conn.method in ["GET", "PUT", "DELETE"] ->
        bucket_tagging(conn, bucket)

      Map.has_key?(params, "cors") and conn.method in ["GET", "PUT", "DELETE"] ->
        bucket_cors(conn, bucket)

      Map.has_key?(params, "lifecycle") and conn.method in ["GET", "PUT", "DELETE"] ->
        bucket_lifecycle(conn, bucket)

      Map.has_key?(params, "acl") and conn.method in ["GET", "PUT"] ->
        bucket_acl(conn, bucket)

      conn.method == "PUT" ->
        create_bucket(conn, bucket)

      conn.method == "DELETE" ->
        delete_bucket(conn, bucket)

      conn.method == "HEAD" ->
        head_bucket(conn, bucket)

      conn.method == "GET" and Map.has_key?(params, "uploads") ->
        list_multipart_uploads(conn, bucket)

      conn.method == "GET" ->
        list_objects(conn, bucket, params)

      conn.method == "POST" ->
        bucket_post(conn, bucket, params)

      true ->
        s3_error(conn, 405, "MethodNotAllowed", "Method not supported")
    end
  end

  # ---------- CORS ----------

  defp bucket_cors(conn, bucket) do
    case conn.method do
      "GET" ->
        with {:ok, user, _} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :read),
             [_ | _] = rules <- Buckets.get_cors_config(b) do
          conn
          |> put_resp_content_type("application/xml")
          |> send_resp(200, Xml.cors_xml(rules))
        else
          [] -> s3_error(conn, 404, "NoSuchCORSConfiguration", "No CORS configuration")
          {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
          {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
        end

      method when method in ["PUT", "DELETE"] ->
        with {:ok, user, _} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :write),
             {:ok, rules} <- read_cors_body(conn, method),
             {:ok, _} <- apply_cors_config(b, rules) do
          send_resp(conn, 200, "")
        else
          {:error, :no_such_bucket} ->
            s3_error(conn, 404, "NoSuchBucket", "Bucket not found")

          {:error, :forbidden} ->
            s3_error(conn, 403, "AccessDenied", "Write access denied")

          {:error, :too_large} ->
            s3_error(conn, 400, "EntityTooLarge", error_message(:too_large))

          {:error, :invalid_xml} ->
            s3_error(conn, 400, "MalformedXML", "Invalid XML")

          {:error, :invalid_cors} ->
            s3_error(conn, 400, "MalformedXML", "Invalid CORS configuration")

          {:error, reason} ->
            s3_error(conn, 403, "AccessDenied", error_message(reason))
        end

      _ ->
        s3_error(conn, 405, "MethodNotAllowed", "Method not supported")
    end
  end

  defp read_cors_body(_conn, "DELETE"), do: {:ok, :delete}

  defp read_cors_body(conn, "PUT") do
    with {:ok, body, _conn} <- read_xml_body(conn),
         {:ok, rules} <- Xml.parse_cors(body) do
      {:ok, rules}
    end
  end

  defp apply_cors_config(bucket, :delete), do: Buckets.delete_cors_config(bucket)

  defp apply_cors_config(bucket, rules) do
    case Buckets.put_cors_config(bucket, rules) do
      {:ok, _} -> {:ok, :done}
      {:error, _} -> {:error, :invalid_cors}
    end
  end

  # Echoes Access-Control-Allow-Origin on object responses when the
  # request Origin matches a bucket CORS rule.
  defp maybe_cors_headers(conn, bucket) do
    origin = conn |> get_req_header("origin") |> List.first()

    case Buckets.cors_allowed?(bucket, origin, conn.method) do
      {:ok, _rule, allowed_origin} ->
        conn
        |> put_resp_header("access-control-allow-origin", allowed_origin)
        |> put_resp_header("vary", "Origin")

      :deny ->
        conn
    end
  end

  # ---------- ACL ----------
  # Canned ACLs are stored and reported (SDK compatibility). Effective
  # access stays grant-based: keeplix offers no anonymous access, so
  # public-read & co. do not elevate permissions.

  defp bucket_acl(conn, bucket) do
    case conn.method do
      "GET" ->
        with {:ok, user, _} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :read) do
          conn
          |> put_resp_content_type("application/xml")
          |> send_resp(200, Xml.acl_xml(owner_name(b), b.acl || "private"))
        else
          {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
          {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
        end

      "PUT" ->
        with {:ok, user, _} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :write),
             {:ok, acl} <- request_canned_acl(conn),
             {:ok, _} <- apply_bucket_acl(b, acl) do
          send_resp(conn, 200, "")
        else
          {:error, :no_such_bucket} ->
            s3_error(conn, 404, "NoSuchBucket", "Bucket not found")

          {:error, :forbidden} ->
            s3_error(conn, 403, "AccessDenied", "Write access denied")

          {:error, :invalid_acl} ->
            s3_error(conn, 400, "InvalidArgument", "Use an x-amz-acl canned ACL")

          {:error, reason} ->
            s3_error(conn, 403, "AccessDenied", error_message(reason))
        end

      _ ->
        s3_error(conn, 405, "MethodNotAllowed", "Method not supported")
    end
  end

  defp object_acl(conn, bucket, key, params) do
    version_id = params["versionId"] || params["versionid"]

    case conn.method do
      "GET" ->
        with {:ok, user, _} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :read),
             {:ok, acl} <- Storage.get_object_acl(bucket, key, version_id) do
          conn
          |> put_version_header(version_id)
          |> put_resp_content_type("application/xml")
          |> send_resp(200, Xml.acl_xml(owner_name(b), acl))
        else
          {:error, :not_found} -> s3_error(conn, 404, "NoSuchKey", "Object not found")
          {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
          {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
        end

      "PUT" ->
        with {:ok, user, _} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :write),
             {:ok, acl} <- request_canned_acl(conn),
             :ok <- Storage.put_object_acl(bucket, key, acl, version_id) do
          conn |> put_version_header(version_id) |> send_resp(200, "")
        else
          {:error, :not_found} ->
            s3_error(conn, 404, "NoSuchKey", "Object not found")

          {:error, :no_such_bucket} ->
            s3_error(conn, 404, "NoSuchBucket", "Bucket not found")

          {:error, :forbidden} ->
            s3_error(conn, 403, "AccessDenied", "Write access denied")

          {:error, :invalid_acl} ->
            s3_error(conn, 400, "InvalidArgument", "Use an x-amz-acl canned ACL")

          {:error, reason} ->
            s3_error(conn, 403, "AccessDenied", error_message(reason))
        end

      _ ->
        s3_error(conn, 405, "MethodNotAllowed", "Method not supported")
    end
  end

  defp owner_name(%Bucket{owner: %{username: username}}), do: username
  defp owner_name(_), do: "unknown"

  # Only canned ACLs via header are supported (explicit Grant XML is not).
  defp request_canned_acl(conn) do
    case get_req_header(conn, "x-amz-acl") do
      [acl | _] ->
        acl = acl |> to_string() |> String.trim()
        if Storage.valid_acl?(acl), do: {:ok, acl}, else: {:error, :invalid_acl}

      [] ->
        {:error, :invalid_acl}
    end
  end

  # Validates an optional `x-amz-acl` on write requests before any byte
  # is stored; applies it to the fresh row afterwards.
  defp check_acl_header(conn) do
    case get_req_header(conn, "x-amz-acl") do
      [] -> :ok
      [_ | _] -> with {:ok, _} <- request_canned_acl(conn), do: :ok
    end
  end

  defp maybe_apply_object_acl(conn, bucket, key) do
    case get_req_header(conn, "x-amz-acl") do
      [acl | _] ->
        unless Storage.dir_key?(key), do: Storage.put_object_acl(bucket, key, String.trim(acl))
        :ok

      [] ->
        :ok
    end
  end

  defp apply_bucket_acl(bucket, acl) do
    case Buckets.update_bucket(bucket, %{acl: acl}) do
      {:ok, _} -> {:ok, :done}
      {:error, _} -> {:error, :invalid_acl}
    end
  end

  # ---------- Lifecycle ----------

  defp bucket_lifecycle(conn, bucket) do
    case conn.method do
      "GET" ->
        with {:ok, user, _} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :read),
             [_ | _] = rules <- Buckets.get_lifecycle_config(b) do
          conn
          |> put_resp_content_type("application/xml")
          |> send_resp(200, Xml.lifecycle_xml(rules))
        else
          [] -> s3_error(conn, 404, "NoSuchLifecycleConfiguration", "No lifecycle configuration")
          {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
          {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
        end

      method when method in ["PUT", "DELETE"] ->
        with {:ok, user, _} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :write),
             {:ok, rules} <- read_lifecycle_body(conn, method),
             {:ok, _} <- apply_lifecycle_config(b, rules) do
          send_resp(conn, 200, "")
        else
          {:error, :no_such_bucket} ->
            s3_error(conn, 404, "NoSuchBucket", "Bucket not found")

          {:error, :forbidden} ->
            s3_error(conn, 403, "AccessDenied", "Write access denied")

          {:error, :too_large} ->
            s3_error(conn, 400, "EntityTooLarge", error_message(:too_large))

          {:error, :invalid_xml} ->
            s3_error(conn, 400, "MalformedXML", "Invalid XML")

          {:error, :invalid_lifecycle} ->
            s3_error(conn, 400, "MalformedXML", "Invalid lifecycle configuration")

          {:error, reason} ->
            s3_error(conn, 403, "AccessDenied", error_message(reason))
        end

      _ ->
        s3_error(conn, 405, "MethodNotAllowed", "Method not supported")
    end
  end

  defp read_lifecycle_body(_conn, "DELETE"), do: {:ok, :delete}

  defp read_lifecycle_body(conn, "PUT") do
    with {:ok, body, _conn} <- read_xml_body(conn),
         {:ok, rules} <- Xml.parse_lifecycle(body) do
      {:ok, rules}
    end
  end

  defp apply_lifecycle_config(bucket, :delete), do: Buckets.delete_lifecycle_config(bucket)

  defp apply_lifecycle_config(bucket, rules) do
    case Buckets.put_lifecycle_config(bucket, rules) do
      {:ok, _} -> {:ok, :done}
      {:error, _} -> {:error, :invalid_lifecycle}
    end
  end

  # ---------- Tagging ----------

  defp bucket_tagging(conn, bucket) do
    case conn.method do
      "GET" ->
        with {:ok, user, _} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :read) do
          conn
          |> put_resp_content_type("application/xml")
          |> send_resp(200, Xml.tagging_xml(Buckets.get_bucket_tags(b)))
        else
          {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
          {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
        end

      method when method in ["PUT", "DELETE"] ->
        with {:ok, user, _} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :write),
             {:ok, tags} <- read_tagging_body(conn, method),
             :ok <- validate_s3_tags(tags),
             {:ok, _} <- apply_bucket_tags(b, tags) do
          send_resp(conn, 200, "")
        else
          {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
          {:error, :forbidden} -> s3_error(conn, 403, "AccessDenied", "Write access denied")
          {:error, :too_large} -> s3_error(conn, 400, "EntityTooLarge", error_message(:too_large))
          {:error, :invalid_xml} -> s3_error(conn, 400, "MalformedXML", "Invalid XML")
          {:error, :invalid_tags} -> s3_error(conn, 400, "InvalidTag", "Invalid tag set")
          {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
        end

      _ ->
        s3_error(conn, 405, "MethodNotAllowed", "Method not supported")
    end
  end

  defp object_tagging(conn, bucket, key, params) do
    version_id = params["versionId"] || params["versionid"]

    case conn.method do
      "GET" ->
        with {:ok, user, _} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :read),
             {:ok, tags} <- Storage.get_object_tags(bucket, key, version_id) do
          conn
          |> put_version_header(version_id)
          |> put_resp_content_type("application/xml")
          |> send_resp(200, Xml.tagging_xml(tags))
        else
          {:error, :not_found} -> s3_error(conn, 404, "NoSuchKey", "Object not found")
          {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
          {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
        end

      method when method in ["PUT", "DELETE"] ->
        with {:ok, user, _} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :write),
             {:ok, tags} <- read_tagging_body(conn, method),
             :ok <- validate_s3_tags(tags),
             :ok <- Storage.put_object_tags(bucket, key, tags, version_id) do
          conn |> put_version_header(version_id) |> send_resp(200, "")
        else
          {:error, :not_found} -> s3_error(conn, 404, "NoSuchKey", "Object not found")
          {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
          {:error, :forbidden} -> s3_error(conn, 403, "AccessDenied", "Write access denied")
          {:error, :too_large} -> s3_error(conn, 400, "EntityTooLarge", error_message(:too_large))
          {:error, :invalid_xml} -> s3_error(conn, 400, "MalformedXML", "Invalid XML")
          {:error, :invalid_tags} -> s3_error(conn, 400, "InvalidTag", "Invalid tag set")
          {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
        end

      _ ->
        s3_error(conn, 405, "MethodNotAllowed", "Method not supported")
    end
  end

  defp read_tagging_body(_conn, "DELETE"), do: {:ok, %{}}

  defp read_tagging_body(conn, "PUT") do
    with {:ok, body, _conn} <- read_xml_body(conn),
         {:ok, tags} <- Xml.parse_tagging(body) do
      {:ok, tags}
    end
  end

  defp validate_s3_tags(tags) do
    case Storage.validate_tags(tags) do
      :ok -> :ok
      _ -> {:error, :invalid_tags}
    end
  end

  defp apply_bucket_tags(bucket, tags) do
    case Buckets.put_bucket_tags(bucket, tags) do
      {:ok, _} -> {:ok, :done}
      {:error, _} -> {:error, :invalid_tags}
    end
  end

  defp put_tag_count_header(conn, stat) do
    count = stat |> Map.get(:tags, %{}) |> map_size()
    put_resp_header(conn, "x-amz-tag-count", to_string(count))
  end

  defp bucket_versioning(conn, bucket) do
    case conn.method do
      "PUT" ->
        with {:ok, user, _key} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :admin),
             {:ok, body, conn} <- read_xml_body(conn),
             {:ok, mode} <- Xml.parse_versioning(body),
             {:ok, _} <- Buckets.set_versioning(b, mode) do
          send_resp(conn, 200, "")
        else
          {:error, :no_such_bucket} ->
            s3_error(conn, 404, "NoSuchBucket", "Bucket not found")

          {:error, :forbidden} ->
            s3_error(conn, 403, "AccessDenied", "Write access denied")

          {:error, :too_large} ->
            s3_error(conn, 400, "EntityTooLarge", error_message(:too_large))

          {:error, :invalid_xml} ->
            s3_error(conn, 400, "MalformedXML", "Invalid XML")

          {:error, :invalid_transition} ->
            s3_error(conn, 400, "InvalidRequest", "Illegal versioning transition")

          {:error, reason} ->
            s3_error(conn, 403, "AccessDenied", error_message(reason))
        end

      "GET" ->
        with {:ok, _user, _key} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket} do
          conn
          |> put_resp_content_type("application/xml")
          |> send_resp(200, Xml.versioning_configuration(b.versioning))
        else
          {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
          {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
        end
    end
  end

  defp create_bucket(conn, bucket) do
    with {:ok, user, key} <- Auth.verify(conn),
         :ok <- require_admin_or_any?(user, :create_bucket),
         :ok <- check_acl_header(conn) do
      Accounts.touch_key_used(key)

      case Buckets.get_bucket(bucket) do
        %Bucket{} ->
          s3_error(conn, 409, "BucketAlreadyOwnedByYou", "Bucket already exists")

        nil ->
          case Buckets.create_bucket(bucket, user) do
            {:ok, created} ->
              case get_req_header(conn, "x-amz-acl") do
                [acl | _] -> Buckets.update_bucket(created, %{acl: String.trim(acl)})
                [] -> :ok
              end

              conn |> put_resp_header("location", "/#{bucket}") |> send_resp(200, "")

            {:error, cs} ->
              s3_error(conn, 400, "InvalidBucketName", inspect_errors(cs))
          end
      end
    else
      {:error, :invalid_acl} ->
        s3_error(conn, 400, "InvalidArgument", "Invalid x-amz-acl value")

      {:error, reason} ->
        s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  end

  defp delete_bucket(conn, bucket) do
    with {:ok, user, key} <- Auth.verify(conn),
         %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
         :ok <- check_perm(user, b, :admin) do
      Accounts.touch_key_used(key)

      case Storage.list_objects(bucket, max_keys: 1) do
        {:ok, %{entries: [_ | _]}} ->
          s3_error(conn, 409, "BucketNotEmpty", "Bucket is not empty")

        _ ->
          case Buckets.delete_bucket(b) do
            :ok -> send_resp(conn, 204, "")
            {:error, _} -> s3_error(conn, 500, "InternalError", "Delete failed")
          end
      end
    else
      {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
      {:error, :forbidden} -> s3_error(conn, 403, "AccessDenied", "Access denied")
      {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  end

  defp head_bucket(conn, bucket) do
    with {:ok, _user, _key} <- Auth.verify(conn),
         %Bucket{} <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket} do
      send_resp(conn, 200, "")
    else
      {:error, :no_such_bucket} -> send_resp(conn, 404, "")
      {:error, _} -> send_resp(conn, 403, "")
    end
  end

  defp list_objects(conn, bucket, params) do
    # GetBucketLocation (?location) must answer with a LocationConstraint.
    # Anything else here would be cached by SDKs as the bucket region and
    # poison subsequent signatures.
    cond do
      Map.has_key?(params, "versions") -> list_versions(conn, bucket, params)
      Map.has_key?(params, "location") -> get_bucket_location(conn, bucket)
      true -> do_list_objects(conn, bucket, params)
    end
  end

  defp list_versions(conn, bucket, params) do
    with {:ok, user, _key} <- Auth.verify(conn),
         %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
         :ok <- check_perm(user, b, :read) do
      max_keys =
        case Map.get(params, "max-keys", "1000") |> to_string() |> Integer.parse() do
          {n, ""} when n > 0 -> min(n, 1000)
          _ -> 1000
        end

      versions = Storage.list_all_versions(bucket, max_keys + 1)
      {page, truncated} = Enum.split(versions, max_keys)

      xml =
        Xml.list_versions(bucket, page, %{
          max_keys: max_keys,
          truncated: truncated != []
        })

      conn |> put_resp_content_type("application/xml") |> send_resp(200, xml)
    else
      {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
      {:error, :forbidden} -> s3_error(conn, 403, "AccessDenied", "Read access denied")
      {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  rescue
    _ -> s3_error(conn, 400, "InvalidArgument", "Invalid list parameters")
  end

  defp get_bucket_location(conn, bucket) do
    with {:ok, _user, _key} <- Auth.verify(conn),
         %Bucket{} <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket} do
      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, Xml.location_constraint())
    else
      {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
      {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  end

  defp do_list_objects(conn, bucket, params) do
    with {:ok, user, key} <- Auth.verify(conn),
         %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
         :ok <- check_perm(user, b, :read) do
      Accounts.touch_key_used(key)

      prefix = Map.get(params, "prefix", "")
      # An empty delimiter means "no grouping", same as absent (S3 behavior).
      delimiter =
        case Map.get(params, "delimiter") do
          "" -> nil
          d -> d
        end

      encoding = Map.get(params, "encoding-type")
      encoding = if encoding in ["url"], do: "url", else: nil
      max_keys = Map.get(params, "max-keys", "1000") |> to_string() |> String.to_integer()
      list_type = Map.get(params, "list-type", "1")
      cont = Map.get(params, "continuation-token")
      marker = Map.get(params, "marker")

      start = cont || marker

      case Storage.list_objects(bucket,
             prefix: prefix,
             delimiter: delimiter,
             max_keys: min(max_keys, 1000),
             continuation_token: start
           ) do
        {:ok, result} ->
          xml =
            if list_type == "2" do
              Xml.list_objects_v2(bucket, prefix, %{
                entries: result.entries,
                prefixes: result.prefixes,
                truncated: result.truncated,
                next_token: result.next_token,
                max_keys: max_keys,
                delimiter: delimiter,
                continuation_token: cont,
                encoding: encoding
              })
            else
              Xml.list_objects_v1(bucket, prefix, %{
                entries: result.entries,
                prefixes: result.prefixes,
                truncated: result.truncated,
                next_token: result.next_token,
                max_keys: max_keys,
                delimiter: delimiter,
                continuation_token: marker,
                encoding: encoding
              })
            end

          conn |> put_resp_content_type("application/xml") |> send_resp(200, xml)

        {:error, :no_such_bucket} ->
          s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
      end
    else
      {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
      {:error, :forbidden} -> s3_error(conn, 403, "AccessDenied", "Read access denied")
      {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  rescue
    _ -> s3_error(conn, 400, "InvalidArgument", "Invalid list parameters")
  end

  defp bucket_post(conn, bucket, params) do
    cond do
      Map.has_key?(params, "delete") ->
        delete_multiple(conn, bucket)

      Map.has_key?(params, "uploads") ->
        list_multipart_uploads(conn, bucket)

      Map.has_key?(params, "uploadId") or Map.has_key?(params, "uploadid") ->
        complete_multipart_stub(conn, bucket, params)

      true ->
        s3_error(conn, 400, "InvalidRequest", "Unknown bucket POST operation")
    end
  end

  defp delete_multiple(conn, bucket) do
    with {:ok, user, _key} <- Auth.verify(conn),
         %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
         :ok <- check_perm(user, b, :write),
         {:ok, body, conn} <- read_xml_body(conn),
         {:ok, keys} <- Xml.parse_delete(body) do
      {deleted, errors} =
        Enum.reduce(keys, {[], []}, fn key, {d, e} ->
          Storage.delete_object(bucket, key)
          {[key | d], e}
        end)

      xml = Xml.delete_result(Enum.reverse(deleted), errors)
      conn |> put_resp_content_type("application/xml") |> send_resp(200, xml)
    else
      {:error, :no_such_bucket} ->
        s3_error(conn, 404, "NoSuchBucket", "Bucket not found")

      {:error, :forbidden} ->
        s3_error(conn, 403, "AccessDenied", "Write access denied")

      {:error, :too_large} ->
        s3_error(conn, 400, "EntityTooLarge", error_message(:too_large))

      {:error, :invalid_xml} ->
        s3_error(conn, 400, "MalformedXML", "Invalid XML")

      {:error, reason} when is_atom(reason) ->
        s3_error(conn, 403, "AccessDenied", error_message(reason))

      {:error, _} ->
        s3_error(conn, 400, "MalformedXML", "Invalid XML")
    end
  end

  # ---------- Objekt ----------

  @spec object(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def object(conn, %{"bucket" => bucket, "key" => key_parts} = params) do
    # Phoenix drops trailing slashes from glob segments, but folder-marker
    # keys ("data/") need them: recover from the raw request path.
    key = key_parts |> List.wrap() |> Enum.join("/")

    key =
      if key != "" and not String.ends_with?(key, "/") and
           String.ends_with?(conn.request_path, "/") do
        key <> "/"
      else
        key
      end

    version_id = params["versionId"] || params["versionid"]

    cond do
      op = unimplemented_param(params, @unimplemented_object_ops) ->
        not_implemented(conn, op)

      Map.has_key?(params, "acl") ->
        object_acl(conn, bucket, key, params)

      Map.has_key?(params, "tagging") ->
        object_tagging(conn, bucket, key, params)

      conn.method == "PUT" and not is_nil(version_id) and
          get_req_header(conn, "x-amz-copy-source") == [] ->
        s3_error(conn, 400, "InvalidRequest", "Cannot PUT a specific version")

      conn.method == "PUT" ->
        put_object(conn, bucket, key, params)

      conn.method == "GET" ->
        get_object(conn, bucket, key, params, version_id)

      conn.method == "DELETE" ->
        delete_object(conn, bucket, key, version_id)

      conn.method == "HEAD" ->
        head_object(conn, bucket, key, version_id)

      conn.method == "POST" ->
        object_post(conn, bucket, key, params)

      true ->
        s3_error(conn, 405, "MethodNotAllowed", "Method not supported")
    end
  end

  defp put_version_header(conn, version_id) when version_id not in [nil, "null"] do
    put_resp_header(conn, "x-amz-version-id", version_id)
  end

  defp put_version_header(conn, _), do: conn

  # S3 CopyObject: PUT with `x-amz-copy-source: /src-bucket/src-key`.
  defp s3_copy_object(conn, bucket, key, params, source) do
    with {:ok, {src_bucket, src_key}} <- parse_copy_source(source),
         :ok <- validate_directive(conn, "x-amz-metadata-directive", ["COPY", "REPLACE"]),
         :ok <- validate_directive(conn, "x-amz-tagging-directive", ["COPY", "REPLACE"]),
         {:ok, user, _s3key} <- Auth.verify(conn),
         %Bucket{} = dest <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
         :ok <- check_perm(user, dest, :write),
         %Bucket{} = src_b <- Buckets.get_bucket(src_bucket) || {:error, :no_such_source_bucket},
         :ok <- check_perm(user, src_b, :read) do
      version_id = params["versionId"] || params["versionid"]

      case copy_source_stat(src_bucket, src_key, version_id) do
        {:ok, src_stat} ->
          cond do
            same_object?(bucket, key, src_bucket, src_key, version_id) and
                directive(conn, "x-amz-metadata-directive") != "REPLACE" ->
              s3_error(
                conn,
                400,
                "InvalidRequest",
                "Self copy requires metadata-directive REPLACE"
              )

            not copy_source_fresh?(conn, src_stat) ->
              s3_error(conn, 412, "PreconditionFailed", "Copy source precondition failed")

            true ->
              do_s3_copy(conn, user, dest, bucket, key, src_bucket, src_key, version_id, src_stat)
          end

        {:error, :not_found} ->
          s3_error(conn, 404, "NoSuchKey", "Copy source not found")
      end
    else
      {:error, :bad_source} ->
        s3_error(conn, 400, "InvalidRequest", "Invalid x-amz-copy-source")

      {:error, :bad_directive} ->
        s3_error(conn, 400, "InvalidArgument", "Invalid directive value")

      {:error, :no_such_bucket} ->
        s3_error(conn, 404, "NoSuchBucket", "Bucket not found")

      {:error, :no_such_source_bucket} ->
        s3_error(conn, 404, "NoSuchBucket", "Copy source bucket not found")

      {:error, :forbidden} ->
        s3_error(conn, 403, "AccessDenied", "Access denied")

      {:error, reason} ->
        s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  end

  defp do_s3_copy(conn, _user, dest, bucket, key, src_bucket, src_key, version_id, src_stat) do
    content_type =
      if directive(conn, "x-amz-metadata-directive") == "REPLACE" do
        get_req_header(conn, "content-type") |> List.first() || "application/octet-stream"
      else
        nil
      end

    with :ok <- Buckets.quota_allows?(dest, src_stat.size),
         :ok <- check_acl_header(conn),
         {:ok, new_stat} <-
           Storage.copy_object(bucket, key, src_bucket, src_key,
             source_version_id: version_id,
             content_type: content_type
           ) do
      # Tags follow the tagging directive (wired with the tagging backend).
      apply_copy_tagging(src_bucket, src_key, version_id, bucket, key, conn)
      maybe_apply_object_acl(conn, bucket, key)

      conn
      |> put_version_header(Map.get(new_stat, :version_id))
      |> maybe_put_copy_source_version(version_id)
      |> put_resp_content_type("application/xml")
      |> send_resp(200, Xml.copy_result(new_stat.etag, new_stat.mtime))
    else
      {:error, :quota_exceeded} ->
        s3_error(conn, 400, "EntityTooLarge", "Bucket quota exceeded")

      {:error, :invalid_acl} ->
        s3_error(conn, 400, "InvalidArgument", "Invalid x-amz-acl value")

      {:error, :object_too_large} ->
        s3_error(conn, 400, "EntityTooLarge", size_error_message(:object_too_large))

      {:error, :key_collision} ->
        s3_error(conn, 400, "InvalidRequest", "Key collides with existing object or prefix")

      {:error, _} ->
        s3_error(conn, 404, "NoSuchKey", "Copy source not found")
    end
  end

  # Copies object tags when tagging-directive=COPY (default); REPLACE
  # applies `x-amz-tagging`. Implemented with the tagging backend.
  defp apply_copy_tagging(src_bucket, src_key, version_id, dest_bucket, dest_key, conn) do
    if directive(conn, "x-amz-tagging-directive") == "REPLACE" do
      case get_req_header(conn, "x-amz-tagging") do
        [tags | _] -> Storage.put_object_tags(dest_bucket, dest_key, Xml.parse_tag_header(tags))
        [] -> Storage.put_object_tags(dest_bucket, dest_key, %{})
      end
    else
      Storage.copy_object_tags(src_bucket, src_key, version_id, dest_bucket, dest_key)
    end

    :ok
  end

  defp maybe_put_copy_source_version(conn, nil), do: conn

  defp maybe_put_copy_source_version(conn, version_id),
    do: put_resp_header(conn, "x-amz-copy-source-version-id", version_id)

  defp parse_copy_source(source) do
    case source
         |> to_string()
         |> URI.decode()
         |> String.trim_leading("/")
         |> String.split("/", parts: 2) do
      [bucket, key] when bucket != "" and key != "" -> {:ok, {bucket, key}}
      _ -> {:error, :bad_source}
    end
  end

  defp directive(conn, header) do
    case get_req_header(conn, header) do
      [value | _] -> value |> to_string() |> String.upcase()
      [] -> "COPY"
    end
  end

  defp validate_directive(conn, header, allowed) do
    if directive(conn, header) in allowed, do: :ok, else: {:error, :bad_directive}
  end

  defp same_object?(bucket, key, src_bucket, src_key, _version_id),
    do: bucket == src_bucket and key == src_key

  defp copy_source_stat(bucket, key, nil) do
    case Storage.stat_object(bucket, key) do
      {:ok, stat} -> {:ok, stat}
      _ -> {:error, :not_found}
    end
  end

  defp copy_source_stat(bucket, key, version_id) do
    case Storage.stat_version(bucket, key, version_id) do
      {:ok, stat} -> {:ok, stat}
      _ -> {:error, :not_found}
    end
  end

  defp copy_source_fresh?(conn, stat) do
    if_match = get_req_header(conn, "x-amz-copy-source-if-match")
    if_unmod = get_req_header(conn, "x-amz-copy-source-if-unmodified-since")
    if_none = get_req_header(conn, "x-amz-copy-source-if-none-match")
    if_mod = get_req_header(conn, "x-amz-copy-source-if-modified-since")

    (if_match == [] or etag_matches?(if_match, stat.etag)) and
      (if_unmod == [] or unmodified_since_ok?(if_unmod, stat.mtime)) and
      (if_none == [] or not etag_matches?(if_none, stat.etag)) and
      (if_mod == [] or modified_since_ok?(if_mod, stat.mtime))
  end

  defp put_object(conn, bucket, key, params) do
    cond do
      get_req_header(conn, "x-amz-copy-source") != [] ->
        [source | _] = get_req_header(conn, "x-amz-copy-source")
        s3_copy_object(conn, bucket, key, params, source)

      Map.has_key?(params, "partNumber") and Map.has_key?(params, "uploadId") ->
        upload_part(conn, params["uploadId"], Map.get(params, "partNumber"))

      Map.has_key?(params, "uploadId") or Map.has_key?(params, "uploadid") ->
        s3_error(conn, 400, "InvalidRequest", "Unknown object operation")

      true ->
        with {:ok, user, s3key} <- Auth.verify(conn),
             %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             :ok <- check_perm(user, b, :write),
             :ok <- check_acl_header(conn),
             :ok <- check_content_length_quota(conn, b),
             {:ok, tmp, conn} <- stream_body_to_temp(conn),
             :ok <- decode_streaming_body(conn, tmp, s3key),
             :ok <- check_tmp_quota(tmp, b) do
          Accounts.touch_key_used(s3key)

          content_type =
            get_req_header(conn, "content-type") |> List.first() || "application/octet-stream"

          case Storage.put_object_from_file(bucket, key, tmp, content_type: content_type) do
            {:ok, stat} ->
              File.rm(tmp)
              maybe_apply_object_acl(conn, bucket, key)

              conn
              |> put_resp_header("etag", "\"#{stat.etag}\"")
              |> put_version_header(Map.get(stat, :version_id))
              |> send_resp(200, "")

            {:error, :invalid_content_type} ->
              File.rm(tmp)
              s3_error(conn, 400, "InvalidRequest", "Invalid content type")

            {:error, :key_collision} ->
              File.rm(tmp)
              s3_error(conn, 400, "InvalidRequest", "Key collides with existing object or prefix")

            {:error, reason} ->
              File.rm(tmp)
              s3_error(conn, 400, "EntityTooLarge", size_error_message(reason))
          end
        else
          {:error, :invalid_streaming_body} ->
            s3_error(conn, 400, "InvalidRequest", "Invalid streaming body")

          {:error, :no_such_bucket} ->
            s3_error(conn, 404, "NoSuchBucket", "Bucket not found")

          {:error, :forbidden} ->
            s3_error(conn, 403, "AccessDenied", "Write access denied")

          {:error, :quota_exceeded} ->
            s3_error(conn, 400, "EntityTooLarge", "Bucket quota exceeded")

          {:error, :object_too_large} ->
            s3_error(conn, 400, "EntityTooLarge", size_error_message(:object_too_large))

          {:error, :key_collision} ->
            s3_error(conn, 400, "InvalidRequest", "Key collides with existing object or prefix")

          {:error, :invalid_acl} ->
            s3_error(conn, 400, "InvalidArgument", "Invalid x-amz-acl value")

          {:error, reason} ->
            s3_error(conn, 403, "AccessDenied", error_message(reason))
        end
    end
  end

  defp get_object(conn, bucket, key, params, version_id) when is_binary(version_id) do
    with %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
         {:ok, user, s3key} <- auth_for_object_read(conn, b),
         :ok <- check_object_read_perm(user, b),
         {:ok, stat} <- Storage.stat_version(bucket, key, version_id) do
      touch_key_used_safe(s3key)
      serve_versioned_object(conn, bucket, key, params, s3key, stat)
    else
      {:marker, row} ->
        conn
        |> put_resp_header("x-amz-delete-marker", "true")
        |> put_version_header(row.version_id)
        |> send_resp(404, Xml.error("NoSuchKey", "Object not found"))

      {:error, :not_found} ->
        s3_error(conn, 404, "NoSuchKey", "Object not found")

      {:error, :no_such_bucket} ->
        s3_error(conn, 404, "NoSuchBucket", "Bucket not found")

      {:error, :forbidden} ->
        s3_error(conn, 403, "AccessDenied", "Read access denied")

      {:error, reason} ->
        s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  end

  defp get_object(conn, bucket, key, params, _version_id) do
    cond do
      Map.has_key?(params, "uploads") ->
        s3_error(conn, 400, "InvalidRequest", "Unknown operation")

      Map.has_key?(params, "uploadId") ->
        list_parts(conn, params["uploadId"] || params["uploadid"])

      true ->
        with %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
             {:ok, user, s3key} <- auth_for_object_read(conn, b),
             :ok <- check_object_read_perm(user, b),
             {:ok, stat} <- Storage.stat_object(bucket, key) do
          touch_key_used_safe(s3key)
          serve_versioned_object(conn, bucket, key, params, s3key, stat)
        else
          {:error, :not_found} ->
            case Storage.get_version(bucket, key, nil) do
              {:marker, row} ->
                conn
                |> put_resp_header("x-amz-delete-marker", "true")
                |> put_version_header(row.version_id)
                |> send_resp(404, Xml.error("NoSuchKey", "Object not found"))

              _ ->
                s3_error(conn, 404, "NoSuchKey", "Object not found")
            end

          {:error, :no_such_bucket} ->
            s3_error(conn, 404, "NoSuchBucket", "Bucket not found")

          {:error, :forbidden} ->
            s3_error(conn, 403, "AccessDenied", "Read access denied")

          {:error, reason} ->
            s3_error(conn, 403, "AccessDenied", error_message(reason))
        end
    end
  end

  defp serve_versioned_object(conn, bucket, key, params, s3key, stat) do
    touch_key_used_safe(s3key)

    case check_preconditions(conn, stat) do
      {:error, :not_modified} ->
        conn
        |> put_resp_header("etag", "\"#{stat.etag}\"")
        |> put_version_header(Map.get(stat, :version_id))
        |> send_resp(304, "")

      {:error, :precondition_failed} ->
        s3_error(conn, 412, "PreconditionFailed", "Precondition failed")

      :ok ->
        case apply_response_overrides(conn, params) do
          {:ok, conn} ->
            ct = overridden_content_type(conn, bucket, key, stat)

            # Object bodies and their content types are user-controlled.
            # Serve them inert: no sniffing, no script execution in our
            # origin (stored-XSS protection).
            conn =
              conn
              |> put_resp_content_type(ct)
              |> put_resp_header("etag", "\"#{stat.etag}\"")
              |> put_resp_header("content-length", to_string(stat.size))
              |> put_resp_header("last-modified", http_date(stat.mtime))
              |> put_resp_header("x-content-type-options", "nosniff")
              |> put_resp_header("content-security-policy", "sandbox")
              |> put_tag_count_header(stat)
              |> put_version_header(Map.get(stat, :version_id))
              |> maybe_cors_headers(bucket)

            # Range-Unterstuetzung (einfach: bytes=start-end)
            case get_req_header(conn, "range") do
              ["bytes=" <> range | _] ->
                serve_range(conn, stat.path, stat.size, range, ct)

              _ ->
                send_file(conn, 200, stat.path)
            end

          {:error, _} ->
            s3_error(conn, 400, "InvalidRequest", "Invalid response override")
        end
    end
  end

  defp overridden_content_type(conn, bucket, key, stat) do
    case get_resp_header(conn, "content-type") do
      [ct | _] when ct != "" -> ct
      _ -> stat.content_type || Storage.get_content_type(bucket, key)
    end
  end

  # RFC 9110 evaluation order: If-Match, If-Unmodified-Since,
  # If-None-Match, If-Modified-Since. Invalid dates are ignored.
  defp check_preconditions(conn, stat) do
    cond do
      (h = get_req_header(conn, "if-match")) != [] and not etag_matches?(h, stat.etag) ->
        {:error, :precondition_failed}

      (h = get_req_header(conn, "if-unmodified-since")) != [] and
          not unmodified_since_ok?(h, stat.mtime) ->
        {:error, :precondition_failed}

      (h = get_req_header(conn, "if-none-match")) != [] and etag_matches?(h, stat.etag) ->
        {:error, :not_modified}

      (h = get_req_header(conn, "if-modified-since")) != [] and
          not modified_since_ok?(h, stat.mtime) ->
        {:error, :not_modified}

      true ->
        :ok
    end
  end

  defp etag_matches?(headers, etag) do
    Enum.any?(headers, fn header ->
      header
      |> String.split(",")
      |> Enum.any?(fn value ->
        normalized =
          value
          |> String.trim()
          |> String.trim_leading("W/")
          |> String.trim("\"")
          |> String.downcase()

        normalized == "*" or (etag != "" and normalized == String.downcase(etag))
      end)
    end)
  end

  defp unmodified_since_ok?([header | _], mtime) do
    case parse_http_date(header) do
      {:ok, since} -> mtime <= since
      :error -> true
    end
  end

  defp modified_since_ok?([header | _], mtime) do
    case parse_http_date(header) do
      {:ok, since} -> mtime > since
      :error -> true
    end
  end

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  defp parse_http_date(value) do
    with [_, day, mon, year, hour, min, sec] <-
           Regex.run(
             ~r/^\w{3}, (\d{1,2}) (\w{3}) (\d{4}) (\d{1,2}):(\d{2}):(\d{2}) GMT$/,
             String.trim(to_string(value))
           ),
         month when is_integer(month) <- @months[mon],
         {d, ""} <- Integer.parse(day),
         {y, ""} <- Integer.parse(year),
         {h, ""} <- Integer.parse(hour),
         {mi, ""} <- Integer.parse(min),
         {s, ""} <- Integer.parse(sec),
         {:ok, date} <- Date.new(y, month, d),
         {:ok, time} <- Time.new(h, mi, s),
         {:ok, dt} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, DateTime.to_unix(dt)}
    else
      _ -> :error
    end
  end

  # S3 response header overrides (`?response-content-type=...` etc.).
  # Values with CR/LF are rejected (header injection).
  @response_overrides [
    {"response-content-type", "content-type"},
    {"response-content-disposition", "content-disposition"},
    {"response-cache-control", "cache-control"},
    {"response-content-language", "content-language"},
    {"response-content-encoding", "content-encoding"},
    {"response-expires", "expires"}
  ]

  defp apply_response_overrides(conn, params) do
    Enum.reduce_while(@response_overrides, {:ok, conn}, fn {param, header}, {:ok, acc} ->
      case Map.get(params, param) do
        nil ->
          {:cont, {:ok, acc}}

        value ->
          if String.contains?(to_string(value), ["\r", "\n"]) do
            {:halt, {:error, :invalid_override}}
          else
            {:cont, {:ok, Plug.Conn.put_resp_header(acc, header, to_string(value))}}
          end
      end
    end)
  end

  defp delete_object(conn, bucket, key, version_id) when is_binary(version_id) do
    with {:ok, user, _key} <- Auth.verify(conn),
         %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
         :ok <- check_perm(user, b, :write),
         :ok <- Storage.delete_version(bucket, key, version_id) do
      conn
      |> put_version_header(version_id)
      |> send_resp(204, "")
    else
      {:error, :no_such_version} -> s3_error(conn, 404, "NoSuchVersion", "Version not found")
      {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
      {:error, :forbidden} -> s3_error(conn, 403, "AccessDenied", "Write access denied")
      {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  end

  defp delete_object(conn, bucket, key, _version_id) do
    with {:ok, user, _key} <- Auth.verify(conn),
         %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
         :ok <- check_perm(user, b, :write) do
      Storage.delete_object(bucket, key)

      conn
      |> maybe_put_delete_marker_headers(bucket, key)
      |> send_resp(204, "")
    else
      {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
      {:error, :forbidden} -> s3_error(conn, 403, "AccessDenied", "Write access denied")
      {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  end

  defp maybe_put_delete_marker_headers(conn, bucket, key) do
    case Storage.get_version(bucket, key, nil) do
      {:marker, row} ->
        conn
        |> put_resp_header("x-amz-delete-marker", "true")
        |> put_version_header(row.version_id)

      {:ok, row} ->
        put_version_header(conn, row.version_id)

      _ ->
        conn
    end
  end

  defp head_object(conn, bucket, key, version_id) when is_binary(version_id) do
    with %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
         {:ok, user, _key} <- auth_for_object_read(conn, b),
         :ok <- check_object_read_perm(user, b),
         {:ok, stat} <- Storage.stat_version(bucket, key, version_id) do
      head_response(conn, bucket, key, stat)
    else
      {:marker, row} ->
        conn
        |> put_resp_header("x-amz-delete-marker", "true")
        |> put_version_header(row.version_id)
        |> send_resp(404, "")

      {:error, :not_found} ->
        send_resp(conn, 404, "")

      {:error, :no_such_bucket} ->
        send_resp(conn, 404, "")

      {:error, :forbidden} ->
        send_resp(conn, 403, "")

      _ ->
        send_resp(conn, 403, "")
    end
  end

  defp head_object(conn, bucket, key, _version_id) do
    with %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
         {:ok, user, _key} <- auth_for_object_read(conn, b),
         :ok <- check_object_read_perm(user, b),
         {:ok, stat} <- Storage.stat_object(bucket, key) do
      head_response(conn, bucket, key, stat)
    else
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, :no_such_bucket} -> send_resp(conn, 404, "")
      {:error, :forbidden} -> send_resp(conn, 403, "")
      _ -> send_resp(conn, 403, "")
    end
  end

  defp head_response(conn, bucket, key, stat) do
    case check_preconditions(conn, stat) do
      {:error, :not_modified} ->
        conn
        |> put_resp_header("etag", "\"#{stat.etag}\"")
        |> put_version_header(Map.get(stat, :version_id))
        |> send_resp(304, "")

      {:error, :precondition_failed} ->
        send_resp(conn, 412, "")

      :ok ->
        conn
        |> put_resp_header("etag", "\"#{stat.etag}\"")
        |> put_resp_header("content-length", to_string(stat.size))
        |> put_resp_header("last-modified", http_date(stat.mtime))
        |> put_resp_content_type(Storage.get_content_type(bucket, key))
        |> put_tag_count_header(stat)
        |> put_version_header(Map.get(stat, :version_id))
        |> maybe_cors_headers(bucket)
        |> send_resp(200, "")
    end
  end

  defp object_post(conn, bucket, key, params) do
    cond do
      Map.has_key?(params, "uploads") ->
        initiate_multipart(conn, bucket, key)

      Map.has_key?(params, "uploadId") or Map.has_key?(params, "uploadid") ->
        complete_multipart(conn, bucket, key, params)

      true ->
        s3_error(conn, 400, "InvalidRequest", "Unknown object POST operation")
    end
  end

  # ---------- Multipart ----------

  defp initiate_multipart(conn, bucket, key) do
    if Keeplix.Storage.dir_key?(key) do
      s3_error(conn, 400, "InvalidRequest", "Invalid object key")
    else
      do_initiate_multipart(conn, bucket, key)
    end
  end

  defp do_initiate_multipart(conn, bucket, key) do
    with {:ok, user, _k} <- Auth.verify(conn),
         %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
         :ok <- check_perm(user, b, :write) do
      ct = get_req_header(conn, "content-type") |> List.first() || "application/octet-stream"

      case Storage.create_multipart(bucket, key, content_type: ct) do
        {:ok, upload_id} ->
          conn
          |> put_resp_content_type("application/xml")
          |> send_resp(200, Xml.initiate_multipart(bucket, key, upload_id))

        {:error, :invalid_content_type} ->
          s3_error(conn, 400, "InvalidRequest", "Invalid content type")
      end
    else
      {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
      {:error, :forbidden} -> s3_error(conn, 403, "AccessDenied", "Write access denied")
      {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  end

  # Meta for Complete: live upload directory, or — for a retried
  # Complete after a successful one (client timeout, then retry) — the
  # stored receipt, verified against the requesting user and target.
  defp complete_target_meta(user, upload_id, bucket, key) do
    case Storage.multipart_meta(upload_id) do
      {:ok, meta} ->
        {:ok, meta}

      {:error, :no_such_upload} ->
        with {:ok, %{bucket: b, key: k}} <- Storage.replay_completed_upload(upload_id),
             true <- b == bucket and k == key,
             %Bucket{} = bkt <- Buckets.get_bucket(b) || {:error, :no_such_bucket},
             :ok <- check_perm(user, bkt, :write) do
          {:ok,
           %{
             "bucket" => b,
             "key" => k,
             "content_type" => "application/octet-stream",
             "replayed" => true
           }}
        else
          {:error, _} = err -> err
          false -> {:error, :no_such_upload}
        end
    end
  end

  defp upload_part(conn, upload_id, part_number) do
    with {n, ""} <- Integer.parse(to_string(part_number)),
         true <- n >= 1 and n <= 10_000,
         {:ok, user, s3key} <- Auth.verify(conn),
         {:ok, meta} <- Storage.multipart_meta(upload_id),
         %Bucket{} = b <- Buckets.get_bucket(meta["bucket"]) || {:error, :no_such_bucket},
         :ok <- check_perm(user, b, :write),
         :ok <- check_content_length_quota(conn, b),
         {:ok, tmp, conn2} <- stream_body_to_temp(conn),
         :ok <- decode_streaming_body(conn2, tmp, s3key),
         :ok <- check_tmp_quota(tmp, b) do
      case Storage.upload_part_from_file(upload_id, n, tmp) do
        {:ok, etag} ->
          File.rm(tmp)

          conn2
          |> put_resp_header("etag", "\"#{etag}\"")
          |> send_resp(200, "")

        {:error, :no_such_upload} ->
          File.rm(tmp)
          s3_error(conn, 404, "NoSuchUpload", "Upload not found")

        {:error, :object_too_large} ->
          File.rm(tmp)
          s3_error(conn, 400, "EntityTooLarge", size_error_message(:object_too_large))
      end
    else
      {:error, :invalid_streaming_body} ->
        s3_error(conn, 400, "InvalidRequest", "Invalid streaming body")

      {:error, :no_such_upload} ->
        s3_error(conn, 404, "NoSuchUpload", "Upload not found")

      {:error, :no_such_bucket} ->
        s3_error(conn, 404, "NoSuchBucket", "Bucket not found")

      {:error, :forbidden} ->
        s3_error(conn, 403, "AccessDenied", "Write access denied")

      {:error, :quota_exceeded} ->
        s3_error(conn, 400, "EntityTooLarge", "Bucket quota exceeded")

      {:error, :object_too_large} ->
        s3_error(conn, 400, "EntityTooLarge", size_error_message(:object_too_large))

      {:error, reason} when is_atom(reason) ->
        s3_error(conn, 403, "AccessDenied", error_message(reason))

      _ ->
        s3_error(conn, 400, "InvalidArgument", "Invalid part number or signature")
    end
  end

  defp complete_multipart(conn, bucket, key, params) do
    upload_id = params["uploadId"] || params["uploadid"]

    with {:ok, user, _k} <- Auth.verify(conn),
         {:ok, meta} <- complete_target_meta(user, upload_id, bucket, key),
         :ok <- check_upload_target(meta, bucket, key),
         %Bucket{} = b <- Buckets.get_bucket(meta["bucket"]) || {:error, :no_such_bucket},
         :ok <- check_perm(user, b, :write),
         :ok <- check_acl_header(conn),
         :ok <- check_complete_quota(meta, upload_id, b),
         {:ok, body, conn} <- read_xml_body(conn),
         {:ok, parts} <- Xml.parse_complete(body),
         :ok <- validate_part_numbers(parts),
         numbers = Enum.map(parts, &elem(&1, 0)),
         {:ok, %{etag: etag, version_id: version_id}} <-
           Storage.complete_multipart(upload_id, numbers) do
      xml = Xml.complete_multipart(meta["bucket"], meta["key"], etag)
      maybe_apply_object_acl(conn, meta["bucket"], meta["key"])

      conn
      |> put_resp_content_type("application/xml")
      |> put_version_header(version_id)
      |> send_resp(200, xml)
    else
      {:error, :no_such_upload} ->
        s3_error(conn, 404, "NoSuchUpload", "Upload not found")

      {:error, :no_such_bucket} ->
        s3_error(conn, 404, "NoSuchBucket", "Bucket not found")

      {:error, :forbidden} ->
        s3_error(conn, 403, "AccessDenied", "Write access denied")

      {:error, :quota_exceeded} ->
        s3_error(conn, 400, "EntityTooLarge", "Bucket quota exceeded")

      {:error, :object_too_large} ->
        s3_error(conn, 400, "EntityTooLarge", size_error_message(:object_too_large))

      {:error, :key_collision} ->
        s3_error(conn, 400, "InvalidRequest", "Key collides with existing object or prefix")

      {:error, :invalid_key} ->
        s3_error(conn, 400, "InvalidRequest", "Invalid object key")

      {:error, :mismatched_target} ->
        s3_error(conn, 400, "InvalidRequest", error_message(:mismatched_target))

      {:error, :invalid_parts} ->
        s3_error(conn, 400, "InvalidRequest", error_message(:invalid_parts))

      {:error, :invalid_part} ->
        s3_error(conn, 400, "InvalidPart", error_message(:invalid_part))

      {:error, :invalid_acl} ->
        s3_error(conn, 400, "InvalidArgument", "Invalid x-amz-acl value")

      {:error, :too_large} ->
        s3_error(conn, 400, "EntityTooLarge", error_message(:too_large))

      {:error, :invalid_xml} ->
        s3_error(conn, 400, "MalformedXML", "Invalid XML")

      {:error, reason} when is_atom(reason) ->
        s3_error(conn, 403, "AccessDenied", error_message(reason))

      {:error, _} ->
        s3_error(conn, 400, "MalformedXML", "Invalid XML")
    end
  end

  # The request URL must address the same object the upload was initiated for.
  defp check_upload_target(%{"bucket" => mb, "key" => mk}, bucket, key) do
    if mb == bucket and mk == key, do: :ok, else: {:error, :mismatched_target}
  end

  defp check_upload_target(_, _, _), do: {:error, :mismatched_target}

  defp validate_part_numbers([]), do: {:error, :invalid_parts}

  defp validate_part_numbers(parts) do
    numbers = Enum.map(parts, &elem(&1, 0))

    if Enum.all?(numbers, &(&1 >= 1 and &1 <= 10_000)) and
         length(Enum.uniq(numbers)) == length(numbers) do
      :ok
    else
      {:error, :invalid_parts}
    end
  end

  defp complete_multipart_stub(conn, _bucket, _params) do
    s3_error(conn, 400, "InvalidRequest", "Missing upload ID")
    |> then(fn _ -> conn end)
  end

  defp list_parts(conn, upload_id) do
    with {:ok, user, _k} <- Auth.verify(conn),
         {:ok, meta} <- Storage.multipart_meta(upload_id),
         %Bucket{} = b <- Buckets.get_bucket(meta["bucket"]) || {:error, :no_such_bucket},
         :ok <- check_perm(user, b, :read),
         {:ok, parts} <- Storage.list_parts(upload_id) do
      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, Xml.list_parts(upload_id, parts))
    else
      {:error, :no_such_upload} -> s3_error(conn, 404, "NoSuchUpload", "Upload not found")
      {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
      {:error, :forbidden} -> s3_error(conn, 403, "AccessDenied", "Read access denied")
      {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  end

  defp list_multipart_uploads(conn, bucket) do
    with {:ok, user, _k} <- Auth.verify(conn),
         %Bucket{} = b <- Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
         :ok <- check_perm(user, b, :read) do
      uploads = Storage.list_multipart_uploads(bucket)

      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, Xml.list_multipart_uploads(bucket, uploads))
    else
      {:error, :no_such_bucket} -> s3_error(conn, 404, "NoSuchBucket", "Bucket not found")
      {:error, :forbidden} -> s3_error(conn, 403, "AccessDenied", "Read access denied")
      {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  end

  # ---------- Helpers ----------

  defp check_perm(user, bucket, :read) do
    if Buckets.can_read?(user, bucket), do: :ok, else: {:error, :forbidden}
  end

  defp check_perm(user, bucket, :write) do
    if Buckets.can_write?(user, bucket), do: :ok, else: {:error, :forbidden}
  end

  defp check_perm(user, bucket, :admin) do
    if Buckets.can_admin?(user, bucket), do: :ok, else: {:error, :forbidden}
  end

  # Object reads: authenticated users go through grants; anonymous
  # requests are served only from public-read buckets (no key usage).
  # Auth failures on private buckets keep their original error.
  defp auth_for_object_read(conn, %Bucket{} = b) do
    case Auth.verify(conn) do
      {:ok, user, s3key} -> {:ok, user, s3key}
      {:error, _} = err -> if Buckets.public_read?(b), do: {:ok, nil, nil}, else: err
    end
  end

  defp check_object_read_perm(nil, %Bucket{} = b) do
    if Buckets.public_read?(b), do: :ok, else: {:error, :forbidden}
  end

  defp check_object_read_perm(user, bucket), do: check_perm(user, bucket, :read)

  defp touch_key_used_safe(nil), do: :ok
  defp touch_key_used_safe(key), do: Accounts.touch_key_used(key)

  defp size_error_message(:object_too_large), do: "Object exceeds maximum size"
  defp size_error_message(_), do: "Storage write failed"

  # Best-effort pre-check using Content-Length (absent for chunked/streaming
  # bodies, which are checked again after buffering).
  defp check_content_length_quota(conn, bucket) do
    case get_req_header(conn, "content-length") do
      [len | _] ->
        case Integer.parse(len) do
          {n, ""} when n >= 0 -> Buckets.quota_allows?(bucket, n)
          _ -> :ok
        end

      [] ->
        :ok
    end
  end

  # Exact post-check on the buffered body; removes the temp file when over quota.
  defp check_tmp_quota(tmp, bucket) do
    with {:ok, %{size: size}} <- File.stat(tmp),
         :ok <- Buckets.quota_allows?(bucket, size) do
      :ok
    else
      _ ->
        File.rm(tmp)
        {:error, :quota_exceeded}
    end
  end

  defp check_complete_quota(%{"replayed" => true}, _upload_id, _bucket), do: :ok

  defp check_complete_quota(_meta, upload_id, bucket) do
    case Storage.list_parts(upload_id) do
      {:ok, parts} ->
        total = Enum.sum(Enum.map(parts, & &1.size))
        Buckets.quota_allows?(bucket, total)

      {:error, _} = err ->
        err
    end
  end

  defp require_admin_or_any?(_user, :create_bucket), do: :ok

  defp s3_error(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(status, Xml.error(code, message))
  end

  defp unimplemented_param(params, ops) do
    Enum.find(ops, &Map.has_key?(params, &1))
  end

  # Signatur zuerst pruefen (Rate-Limit/Key-Tracking), dann 501.
  defp not_implemented(conn, op) do
    with {:ok, _, _} <- Auth.verify(conn) do
      s3_error(conn, 501, "NotImplemented", "Operation #{op} is not implemented")
    else
      {:error, reason} -> s3_error(conn, 403, "AccessDenied", error_message(reason))
    end
  end

  defp error_message(:missing_auth), do: "Missing authentication"
  defp error_message(:signature_mismatch), do: "Invalid signature"
  defp error_message(:unknown_key), do: "Unknown access key"
  defp error_message(:key_disabled), do: "Key disabled"
  defp error_message(:user_inactive), do: "User disabled"
  defp error_message(:invalid_service), do: "Invalid service"
  defp error_message(:presigned_expired), do: "Presigned URL expired"
  defp error_message(:presigned_expiry_too_long), do: "Presigned URL expiry exceeds 7 days"
  defp error_message(:request_expired), do: "Request timestamp outside allowed skew"
  defp error_message(:missing_date), do: "Missing x-amz-date header"
  defp error_message(:invalid_date), do: "Invalid date"
  defp error_message(:mismatched_target), do: "Upload target does not match request"
  defp error_message(:invalid_parts), do: "Invalid part list"
  defp error_message(:invalid_part), do: "Invalid part"
  defp error_message(:too_large), do: "Request body too large"
  defp error_message(:missing_signed_header), do: "Missing signed header"
  defp error_message(:invalid_xml), do: "Invalid XML"
  defp error_message(:malformed_xml), do: "Invalid XML"
  defp error_message(other), do: "Access denied (#{inspect(other)})"

  defp inspect_errors(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> inspect()
  end

  # XML control-plane bodies (DeleteObjects, CompleteMultipartUpload) are
  # small by nature; cap them hard so malicious payloads cannot exhaust memory.
  @max_xml_body 1_000_000

  defp read_xml_body(conn) do
    case Plug.Conn.read_body(conn, length: @max_xml_body) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _, _} -> {:error, :too_large}
      {:error, _} = err -> err
    end
  end

  defp stream_body_to_temp(conn) do
    tmp =
      Path.join(
        Keeplix.Storage.staging_dir(),
        "keeplix-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
      )

    {:ok, file} = File.open(tmp, [:write, :binary])
    do_stream(conn, file, tmp, 0)
  end

  # Streams the request body to disk with a running total: bodies larger
  # than max_object_bytes are aborted before they can fill the disk.
  defp do_stream(conn, file, tmp, written) do
    max = Keeplix.Storage.max_object_bytes()

    case Plug.Conn.read_body(conn, length: 8_000_000) do
      {status, chunk, conn} when status in [:ok, :more] ->
        total = written + byte_size(chunk)

        if total > max do
          File.close(file)
          File.rm(tmp)
          {:error, :object_too_large}
        else
          IO.binwrite(file, chunk)

          if status == :ok do
            File.close(file)
            {:ok, tmp, conn}
          else
            do_stream(conn, file, tmp, total)
          end
        end

      {:error, _} = err ->
        File.close(file)
        File.rm(tmp)
        err
    end
  end

  defp decode_streaming_body(conn, tmp, s3key) do
    cond do
      Keeplix.S3.Streaming.streaming?(conn) ->
        case Keeplix.S3.Auth.streaming_context(conn, s3key.secret) do
          {:ok, ctx} ->
            try do
              Keeplix.S3.Streaming.verify_and_decode_file!(tmp, ctx)
            rescue
              _ -> {:error, :invalid_streaming_body}
            end

          {:error, _} ->
            {:error, :invalid_streaming_body}
        end

      Keeplix.S3.Streaming.unsigned_streaming?(conn) ->
        try do
          Keeplix.S3.Streaming.decode_file_unsigned!(tmp)
        rescue
          _ -> {:error, :invalid_streaming_body}
        end

      true ->
        :ok
    end
  end

  @range_chunk_size 64 * 1024

  defp serve_range(conn, path, size, range, ct) do
    case parse_range(range, size) do
      {:ok, from, to} ->
        len = to - from + 1

        conn
        |> put_resp_content_type(ct)
        |> put_resp_header("content-range", "bytes #{from}-#{to}/#{size}")
        |> put_resp_header("content-length", to_string(len))
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "sandbox")
        |> send_chunked(206)
        |> stream_range(path, from, len)

      :error ->
        send_resp(conn, 416, "")
    end
  end

  # Streams [from, from + len) without loading the file into memory.
  defp stream_range(conn, path, from, len) do
    with {:ok, file} <- :file.open(path, [:read, :binary, :raw]),
         {:ok, _} <- :file.position(file, {:bof, from}) do
      try do
        send_range_chunks(conn, file, len)
      after
        :file.close(file)
      end
    else
      _ -> conn
    end
  end

  defp send_range_chunks(conn, _file, 0), do: conn

  defp send_range_chunks(conn, file, remaining) do
    case :file.read(file, min(remaining, @range_chunk_size)) do
      {:ok, data} ->
        case chunk(conn, data) do
          {:ok, conn} -> send_range_chunks(conn, file, remaining - byte_size(data))
          {:error, _} -> conn
        end

      _ ->
        conn
    end
  end

  defp parse_range(range, size) do
    case String.split(range, "-", parts: 2) do
      [from_s, to_s] ->
        with {from, ""} <- Integer.parse(from_s),
             {to, ""} when to_s != "" <- Integer.parse(to_s),
             true <- from >= 0 and to >= from and to < size do
          {:ok, from, to}
        else
          _ ->
            # suffix oder offenes Ende
            if to_s == "" do
              with {from, ""} <- Integer.parse(from_s), true <- from < size do
                {:ok, from, size - 1}
              else
                _ -> :error
              end
            else
              :error
            end
        end

      _ ->
        :error
    end
  end

  defp http_date(ts) when is_integer(ts) do
    ts |> DateTime.from_unix!() |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end
end
