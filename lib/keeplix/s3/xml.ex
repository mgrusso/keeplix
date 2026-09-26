defmodule Keeplix.S3.Xml do
  @moduledoc """
  S3-style XML responses.
  """

  @spec error(String.t(), String.t(), String.t()) :: String.t()
  def error(code, message, resource \\ "") do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Error>
      <Code>#{escape(code)}</Code>
      <Message>#{escape(message)}</Message>
      <Resource>#{escape(resource)}</Resource>
    </Error>
    """
  end

  @spec list_buckets([Keeplix.Buckets.Bucket.t()], String.t()) :: String.t()
  def list_buckets(buckets, owner_name \\ "keeplix") do
    items =
      Enum.map_join(buckets, "", fn b ->
        date = format_date(b.inserted_at)

        """
        <Bucket><Name>#{escape(b.name)}</Name><CreationDate>#{date}</CreationDate></Bucket>
        """
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Owner><ID>keeplix</ID><DisplayName>#{escape(owner_name)}</DisplayName></Owner>
      <Buckets>#{items}</Buckets>
    </ListAllMyBucketsResult>
    """
  end

  @spec list_objects_v2(String.t(), String.t() | nil, map()) :: String.t()
  def list_objects_v2(bucket, prefix, opts) do
    entries = Map.get(opts, :entries, [])
    prefixes = Map.get(opts, :prefixes, [])
    truncated = Map.get(opts, :truncated, false)
    next_token = Map.get(opts, :next_token)
    max_keys = Map.get(opts, :max_keys, 1000)
    delimiter = Map.get(opts, :delimiter)
    cont_token = Map.get(opts, :continuation_token)
    encoding = Map.get(opts, :encoding)

    contents =
      Enum.map_join(entries, "", fn e ->
        date = format_date_unix(e.mtime)

        """
        <Contents><Key>#{escape(encode_key(e.key, encoding))}</Key><LastModified>#{date}</LastModified><ETag>&quot;#{e.etag}&quot;</ETag><Size>#{e.size}</Size><StorageClass>STANDARD</StorageClass></Contents>
        """
      end)

    prefix_xml =
      Enum.map_join(prefixes, "", fn p ->
        "<CommonPrefixes><Prefix>#{escape(encode_key(p, encoding))}</Prefix></CommonPrefixes>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>#{escape(bucket)}</Name>
      <Prefix>#{escape(encode_key(prefix || "", encoding))}</Prefix>
      <KeyCount>#{length(entries)}</KeyCount>
      <MaxKeys>#{max_keys}</MaxKeys>
      #{if encoding, do: "<EncodingType>#{encoding}</EncodingType>", else: ""}
      <IsTruncated>#{if truncated, do: "true", else: "false"}</IsTruncated>
      #{if delimiter, do: "<Delimiter>#{escape(delimiter)}</Delimiter>", else: ""}
      #{if cont_token, do: "<ContinuationToken>#{escape(encode_key(cont_token, encoding))}</ContinuationToken>", else: ""}
      #{if next_token && truncated, do: "<NextContinuationToken>#{escape(encode_key(next_token, encoding))}</NextContinuationToken>", else: ""}
      #{contents}#{prefix_xml}
    </ListBucketResult>
    """
  end

  # Percent-encodes keys when the client requested encoding-type=url,
  # so SDKs can decode them back (QueryUnescape-compatible).
  defp encode_key(key, "url"), do: URI.encode(key, &URI.char_unreserved?/1)
  defp encode_key(key, _), do: key

  @spec list_objects_v1(String.t(), String.t() | nil, map()) :: String.t()
  def list_objects_v1(bucket, prefix, opts) do
    # V1 shares the V2 shape with renamed markers.
    v2 = list_objects_v2(bucket, prefix, opts)

    v2
    |> String.replace("ListBucketResult", "ListBucketResult")
    |> String.replace("<ContinuationToken>", "<Marker>")
    |> String.replace("</ContinuationToken>", "</Marker>")
    |> String.replace("<NextContinuationToken>", "<NextMarker>")
    |> String.replace("</NextContinuationToken>", "</NextMarker>")
  end

  @spec delete_result([String.t()], [%{key: String.t(), code: String.t(), message: String.t()}]) ::
          String.t()
  def delete_result(deleted, errors) do
    d =
      Enum.map_join(deleted, "", fn key -> "<Deleted><Key>#{escape(key)}</Key></Deleted>" end)

    e =
      Enum.map_join(errors, "", fn %{key: k, code: c, message: m} ->
        "<Error><Key>#{escape(k)}</Key><Code>#{escape(c)}</Code><Message>#{escape(m)}</Message></Error>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">#{d}#{e}</DeleteResult>
    """
  end

  @spec initiate_multipart(String.t(), String.t(), String.t()) :: String.t()
  def initiate_multipart(bucket, key, upload_id) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Bucket>#{escape(bucket)}</Bucket><Key>#{escape(key)}</Key><UploadId>#{escape(upload_id)}</UploadId>
    </InitiateMultipartUploadResult>
    """
  end

  @spec complete_multipart(String.t(), String.t(), String.t()) :: String.t()
  def complete_multipart(bucket, key, etag) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Bucket>#{escape(bucket)}</Bucket><Key>#{escape(key)}</Key><ETag>&quot;#{etag}&quot;</ETag>
    </CompleteMultipartUploadResult>
    """
  end

  @spec location_constraint(String.t()) :: String.t()
  def location_constraint(region \\ "us-east-1") do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <LocationConstraint xmlns="http://s3.amazonaws.com/doc/2006-03-01/">#{escape(region)}</LocationConstraint>
    """
  end

  @doc """
  Parses a VersioningConfiguration body, returns `"enabled"` or `"suspended"`.
  """
  @spec parse_versioning(String.t()) :: {:ok, String.t()} | {:error, :invalid_xml}
  def parse_versioning(xml_body) when is_binary(xml_body) do
    import SweetXml

    with :ok <- check_no_directives(xml_body) do
      try do
        case xml_body |> xpath(~x"//Status/text()"s) |> to_string() |> String.trim() do
          "Enabled" -> {:ok, "enabled"}
          "Suspended" -> {:ok, "suspended"}
          _ -> {:error, :invalid_xml}
        end
      rescue
        _ -> {:error, :invalid_xml}
      catch
        :exit, _ -> {:error, :invalid_xml}
      end
    end
  end

  @spec versioning_configuration(String.t() | nil) :: String.t()
  def versioning_configuration("enabled") do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>
    """
  end

  def versioning_configuration("suspended") do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Suspended</Status></VersioningConfiguration>
    """
  end

  def versioning_configuration(_) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"></VersioningConfiguration>
    """
  end

  @spec list_versions(String.t(), [Keeplix.Storage.Object.t()], map()) :: String.t()
  def list_versions(bucket, versions, opts) do
    max_keys = Map.get(opts, :max_keys, 1000)
    truncated = Map.get(opts, :truncated, false)

    items =
      Enum.map_join(versions, "", fn v ->
        date = format_date(v.updated_at)
        latest = if v.is_latest, do: "true", else: "false"

        if v.deleted do
          """
          <DeleteMarker><Key>#{escape(v.key)}</Key><VersionId>#{escape(v.version_id)}</VersionId><IsLatest>#{latest}</IsLatest><LastModified>#{date}</LastModified></DeleteMarker>
          """
        else
          """
          <Version><Key>#{escape(v.key)}</Key><VersionId>#{escape(v.version_id)}</VersionId><IsLatest>#{latest}</IsLatest><LastModified>#{date}</LastModified><ETag>&quot;#{v.etag}&quot;</ETag><Size>#{v.size}</Size><StorageClass>STANDARD</StorageClass></Version>
          """
        end
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListVersionsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>#{escape(bucket)}</Name>
      <MaxKeys>#{max_keys}</MaxKeys>
      <IsTruncated>#{if truncated, do: "true", else: "false"}</IsTruncated>
      #{items}
    </ListVersionsResult>
    """
  end

  @spec list_multipart_uploads(String.t(), [map()]) :: String.t()
  def list_multipart_uploads(bucket, uploads) do
    items =
      Enum.map_join(uploads, "", fn u ->
        initiated = if u.initiated, do: "<Initiated>#{escape(u.initiated)}</Initiated>", else: ""

        "<Upload><Key>#{escape(u.key)}</Key><UploadId>#{escape(u.upload_id)}</UploadId>#{initiated}<StorageClass>STANDARD</StorageClass></Upload>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListMultipartUploadsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Bucket>#{escape(bucket)}</Bucket><IsTruncated>false</IsTruncated>#{items}
    </ListMultipartUploadsResult>
    """
  end

  @cors_methods ~w(GET PUT POST DELETE HEAD)

  @doc """
  Parses a CORSConfiguration body into validated rule maps.
  """
  @spec parse_cors(String.t()) :: {:ok, [map()]} | {:error, :invalid_xml | :invalid_cors}
  def parse_cors(xml_body) when is_binary(xml_body) do
    import SweetXml

    with :ok <- check_no_directives(xml_body) do
      try do
        rules =
          xml_body
          |> xpath(~x"//CORSRule"l)
          |> Enum.map(fn rule ->
            %{
              "allowed_origins" =>
                rule |> xpath(~x"./AllowedOrigin/text()"sl) |> Enum.map(&to_string/1),
              "allowed_methods" =>
                rule
                |> xpath(~x"./AllowedMethod/text()"sl)
                |> Enum.map(&(&1 |> to_string() |> String.upcase())),
              "allowed_headers" =>
                rule |> xpath(~x"./AllowedHeader/text()"sl) |> Enum.map(&to_string/1),
              "expose_headers" =>
                rule |> xpath(~x"./ExposeHeader/text()"sl) |> Enum.map(&to_string/1),
              "max_age" =>
                rule |> xpath(~x"./MaxAgeSeconds/text()"s) |> to_string() |> parse_max_age()
            }
          end)

        validate_cors_rules(rules)
      rescue
        _ -> {:error, :invalid_xml}
      catch
        :exit, _ -> {:error, :invalid_xml}
      end
    end
  end

  defp parse_max_age(""), do: nil

  defp parse_max_age(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> :invalid
    end
  end

  defp validate_cors_rules([]), do: {:error, :invalid_cors}

  defp validate_cors_rules(rules) when length(rules) > 100, do: {:error, :invalid_cors}

  defp validate_cors_rules(rules) do
    if Enum.all?(rules, &valid_cors_rule?/1), do: {:ok, rules}, else: {:error, :invalid_cors}
  end

  defp valid_cors_rule?(%{
         "allowed_origins" => [_ | _],
         "allowed_methods" => [_ | _] = methods,
         "max_age" => max_age
       }) do
    Enum.all?(methods, &(&1 in @cors_methods)) and
      (is_nil(max_age) or (is_integer(max_age) and max_age >= 0))
  end

  defp valid_cors_rule?(_), do: false

  @spec cors_xml([map()]) :: String.t()
  def cors_xml(rules) do
    items =
      Enum.map_join(rules, "", fn r ->
        origins =
          Enum.map_join(
            r["allowed_origins"] || [],
            "",
            &"<AllowedOrigin>#{escape(&1)}</AllowedOrigin>"
          )

        methods =
          Enum.map_join(
            r["allowed_methods"] || [],
            "",
            &"<AllowedMethod>#{escape(&1)}</AllowedMethod>"
          )

        headers =
          Enum.map_join(
            r["allowed_headers"] || [],
            "",
            &"<AllowedHeader>#{escape(&1)}</AllowedHeader>"
          )

        expose =
          Enum.map_join(
            r["expose_headers"] || [],
            "",
            &"<ExposeHeader>#{escape(&1)}</ExposeHeader>"
          )

        max_age = if r["max_age"], do: "<MaxAgeSeconds>#{r["max_age"]}</MaxAgeSeconds>", else: ""

        "<CORSRule>#{origins}#{methods}#{headers}#{expose}#{max_age}</CORSRule>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">#{items}</CORSConfiguration>
    """
  end

  @doc """
  Parses a LifecycleConfiguration body. Supported: Enabled/Disabled rules
  with Prefix filter and Expiration in Days.
  """
  @spec parse_lifecycle(String.t()) ::
          {:ok, [map()]} | {:error, :invalid_xml | :invalid_lifecycle}
  def parse_lifecycle(xml_body) when is_binary(xml_body) do
    import SweetXml

    with :ok <- check_no_directives(xml_body) do
      try do
        rules =
          xml_body
          |> xpath(~x"//Rule"l)
          |> Enum.map(fn rule ->
            prefix =
              case rule |> xpath(~x"./Filter/Prefix/text()"s) |> to_string() do
                "" -> rule |> xpath(~x"./Prefix/text()"s) |> to_string()
                p -> p
              end

            %{
              "id" => rule |> xpath(~x"./ID/text()"s) |> to_string(),
              "status" => rule |> xpath(~x"./Status/text()"s) |> to_string(),
              "prefix" => prefix,
              "days" =>
                rule |> xpath(~x"./Expiration/Days/text()"s) |> to_string() |> parse_days(),
              "has_date" => rule |> xpath(~x"./Expiration/Date/text()"s) |> to_string() != ""
            }
          end)

        validate_lifecycle_rules(rules)
      rescue
        _ -> {:error, :invalid_xml}
      catch
        :exit, _ -> {:error, :invalid_xml}
      end
    end
  end

  defp parse_days(""), do: :missing

  defp parse_days(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n >= 1 -> n
      _ -> :invalid
    end
  end

  defp validate_lifecycle_rules([]), do: {:error, :invalid_lifecycle}

  defp validate_lifecycle_rules(rules) when length(rules) > 100, do: {:error, :invalid_lifecycle}

  defp validate_lifecycle_rules(rules) do
    if Enum.all?(rules, &valid_lifecycle_rule?/1),
      do: {:ok, Enum.map(rules, &Map.delete(&1, "has_date"))},
      else: {:error, :invalid_lifecycle}
  end

  defp valid_lifecycle_rule?(%{"status" => s, "days" => days, "has_date" => false})
       when s in ["Enabled", "Disabled"] and is_integer(days),
       do: true

  defp valid_lifecycle_rule?(_), do: false

  @spec lifecycle_xml([map()]) :: String.t()
  def lifecycle_xml(rules) do
    items =
      Enum.map_join(rules, "", fn r ->
        id = if r["id"] not in [nil, ""], do: "<ID>#{escape(r["id"])}</ID>", else: ""

        """
        <Rule>#{id}<Status>#{escape(r["status"])}</Status>\
        <Filter><Prefix>#{escape(r["prefix"] || "")}</Prefix></Filter>\
        <Expiration><Days>#{r["days"]}</Days></Expiration></Rule>
        """
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">#{items}</LifecycleConfiguration>
    """
  end

  @doc """
  AccessControlPolicy for a canned ACL. `owner_id` is the owner's
  username (keeplix has no canonical IDs).
  """
  @spec acl_xml(String.t(), String.t()) :: String.t()
  def acl_xml(owner_id, canned) do
    grants =
      case canned do
        "private" ->
          grant("FULL_CONTROL", id_grantee(owner_id))

        "bucket-owner-read" ->
          grant("FULL_CONTROL", id_grantee(owner_id))

        "bucket-owner-full-control" ->
          grant("FULL_CONTROL", id_grantee(owner_id))

        "public-read" ->
          grant("FULL_CONTROL", id_grantee(owner_id)) <>
            grant("READ", uri_grantee("http://acs.amazonaws.com/groups/global/AllUsers"))

        "public-read-write" ->
          grant("FULL_CONTROL", id_grantee(owner_id)) <>
            grant("READ", uri_grantee("http://acs.amazonaws.com/groups/global/AllUsers")) <>
            grant("WRITE", uri_grantee("http://acs.amazonaws.com/groups/global/AllUsers"))

        "authenticated-read" ->
          grant("FULL_CONTROL", id_grantee(owner_id)) <>
            grant(
              "READ",
              uri_grantee("http://acs.amazonaws.com/groups/global/AuthenticatedUsers")
            )

        "log-delivery-write" ->
          grant("FULL_CONTROL", id_grantee(owner_id)) <>
            grant("WRITE", uri_grantee("http://acs.amazonaws.com/groups/s3/LogDelivery"))

        _ ->
          grant("FULL_CONTROL", id_grantee(owner_id))
      end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <AccessControlPolicy xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Owner><ID>#{escape(owner_id)}</ID></Owner><AccessControlList>#{grants}</AccessControlList></AccessControlPolicy>
    """
  end

  defp grant(permission, grantee) do
    "<Grant>#{grantee}<Permission>#{permission}</Permission></Grant>"
  end

  defp id_grantee(id), do: "<Grantee><ID>#{escape(id)}</ID></Grantee>"

  defp uri_grantee(uri), do: "<Grantee><URI>#{escape(uri)}</URI></Grantee>"

  @spec tagging_xml(map()) :: String.t()
  def tagging_xml(tags) do
    items =
      tags
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("", fn {k, v} ->
        "<Tag><Key>#{escape(k)}</Key><Value>#{escape(v)}</Value></Tag>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Tagging xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><TagSet>#{items}</TagSet></Tagging>
    """
  end

  @doc """
  Parses a Tagging body into a string map.
  """
  @spec parse_tagging(String.t()) :: {:ok, map()} | {:error, :invalid_xml}
  def parse_tagging(xml_body) when is_binary(xml_body) do
    import SweetXml

    with :ok <- check_no_directives(xml_body) do
      try do
        tags =
          xml_body
          |> xpath(~x"//Tag"l)
          |> Enum.map(fn tag ->
            {tag |> xpath(~x"./Key/text()"s) |> to_string(),
             tag |> xpath(~x"./Value/text()"s) |> to_string()}
          end)
          |> Map.new()

        {:ok, tags}
      rescue
        _ -> {:error, :invalid_xml}
      catch
        :exit, _ -> {:error, :invalid_xml}
      end
    end
  end

  @doc """
  Parses `x-amz-tagging` header format (`k1=v1&k2=v2`, URL-encoded).
  """
  @spec parse_tag_header(String.t() | nil) :: map()
  def parse_tag_header(nil), do: %{}
  def parse_tag_header(""), do: %{}

  def parse_tag_header(header) do
    header
    |> to_string()
    |> String.split("&", trim: true)
    |> Enum.reduce(%{}, fn part, acc ->
      case String.split(part, "=", parts: 2) do
        [k, v] -> Map.put(acc, URI.decode(k), URI.decode(v))
        [k] -> Map.put(acc, URI.decode(k), "")
      end
    end)
  end

  @spec copy_result(String.t(), integer()) :: String.t()
  def copy_result(etag, mtime_unix) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <CopyObjectResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <LastModified>#{format_date_unix(mtime_unix)}</LastModified><ETag>&quot;#{etag}&quot;</ETag>
    </CopyObjectResult>
    """
  end

  @spec list_parts(String.t(), [Keeplix.Storage.multipart_part()]) :: String.t()
  def list_parts(upload_id, parts) do
    items =
      Enum.map_join(parts, "", fn p ->
        "<Part><PartNumber>#{p.number}</PartNumber><ETag>&quot;#{p.etag}&quot;</ETag><Size>#{p.size}</Size></Part>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListPartsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <UploadId>#{escape(upload_id)}</UploadId>#{items}
    </ListPartsResult>
    """
  end

  @doc """
  Parses a DeleteMultipleObjects body, returns the key list.

  Bodies with DTD/DOCTYPE/ENTITY markup are rejected outright (XXE and
  entity-expansion protection): S3 request bodies never need them.
  """
  @spec parse_delete(String.t()) :: {:ok, [String.t()]} | {:error, :invalid_xml}
  def parse_delete(xml_body) when is_binary(xml_body) do
    import SweetXml

    with :ok <- check_no_directives(xml_body) do
      try do
        keys =
          xml_body
          |> xpath(~x"//Key/text()"l)
          |> Enum.map(&to_string/1)

        {:ok, keys}
      rescue
        _ -> {:error, :invalid_xml}
      catch
        :exit, _ -> {:error, :invalid_xml}
      end
    end
  end

  @doc """
  Parses a CompleteMultipartUpload body: [{part_number, etag}]
  """
  @spec parse_complete(String.t()) :: {:ok, [{integer(), String.t()}]} | {:error, :invalid_xml}
  def parse_complete(xml_body) when is_binary(xml_body) do
    import SweetXml

    with :ok <- check_no_directives(xml_body) do
      try do
        parts =
          xml_body
          |> xpath(~x"//Part"l)
          |> Enum.map(fn part ->
            n = part |> xpath(~x"./PartNumber/text()"s) |> to_string() |> String.to_integer()
            etag = part |> xpath(~x"./ETag/text()"s) |> to_string() |> String.trim("\"")
            {n, etag}
          end)
          |> Enum.sort_by(&elem(&1, 0))

        {:ok, parts}
      rescue
        _ -> {:error, :invalid_xml}
      catch
        :exit, _ -> {:error, :invalid_xml}
      end
    end
  end

  defp check_no_directives(body) do
    if Regex.match?(~r/<!\s*(doctype|entity)/i, body) do
      {:error, :invalid_xml}
    else
      :ok
    end
  end

  defp escape(nil), do: ""

  defp escape(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp format_date(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp format_date(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_date(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end

  defp format_date_unix(ts) when is_integer(ts) do
    DateTime.from_unix!(ts) |> DateTime.to_iso8601()
  end
end
