defmodule Keeplix.S3.XmlTest do
  @moduledoc """
  XML request parsing rejects DTD/DOCTYPE/ENTITY markup (XXE and
  entity-expansion protection, P1).
  """
  use ExUnit.Case, async: true

  alias Keeplix.S3.Xml

  test "parse_delete accepts plain bodies" do
    body = ~s(<Delete><Object><Key>a/b.txt</Key></Object></Delete>)
    assert {:ok, ["a/b.txt"]} = Xml.parse_delete(body)
  end

  test "parse_delete rejects DOCTYPE" do
    body =
      ~s(<?xml version="1.0"?><!DOCTYPE Delete [<!ENTITY x "evil">]><Delete><Object><Key>a</Key></Object></Delete>)

    assert {:error, :invalid_xml} = Xml.parse_delete(body)
  end

  test "directive detection is case-insensitive and whitespace-tolerant" do
    assert {:error, :invalid_xml} = Xml.parse_delete("<!DocType <Delete/>")
    assert {:error, :invalid_xml} = Xml.parse_delete("<!\n  ENTITY x 'y'><Delete/>")
    assert {:error, :invalid_xml} = Xml.parse_complete("<!DOCTYPE Foo><CompleteMultipartUpload/>")
  end

  test "parse_complete accepts plain bodies" do
    body =
      ~s(<CompleteMultipartUpload><Part><PartNumber>2</PartNumber><ETag>"abc"</ETag></Part></CompleteMultipartUpload>)

    assert {:ok, [{2, "abc"}]} = Xml.parse_complete(body)
  end

  test "garbage stays invalid" do
    assert {:error, :invalid_xml} = Xml.parse_delete("not xml at all <")

    assert {:error, :invalid_xml} =
             Xml.parse_complete("<Part><PartNumber>NaN</PartNumber></Part>")
  end
end
