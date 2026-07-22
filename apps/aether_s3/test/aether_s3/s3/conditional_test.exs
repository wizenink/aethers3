defmodule AetherS3.S3.ConditionalTest do
  use ExUnit.Case, async: true

  alias AetherS3.S3.Conditional

  @etag "d41d8cd98f00b204e9800998ecf8427e"
  # 2026-07-20 12:00:00Z
  @modified ~U[2026-07-20 12:00:00Z]

  defp meta(overrides \\ %{}) do
    Map.merge(%{etag: @etag, last_modified: @modified}, overrides)
  end

  describe "read: If-Match" do
    test "matching etag serves the object" do
      assert Conditional.evaluate_read([{"if-match", ~s("#{@etag}")}], meta()) == :ok
    end

    test "unquoted and weak forms both match" do
      assert Conditional.evaluate_read([{"if-match", @etag}], meta()) == :ok
      assert Conditional.evaluate_read([{"if-match", ~s(W/"#{@etag}")}], meta()) == :ok
    end

    test "a list matches if any member matches" do
      value = ~s("nope", "#{@etag}")
      assert Conditional.evaluate_read([{"if-match", value}], meta()) == :ok
    end

    test "* matches any existing object" do
      assert Conditional.evaluate_read([{"if-match", "*"}], meta()) == :ok
    end

    test "non-matching etag is a precondition failure" do
      assert Conditional.evaluate_read([{"if-match", ~s("other")}], meta()) ==
               :precondition_failed
    end
  end

  describe "read: If-None-Match" do
    test "matching etag is not-modified" do
      assert Conditional.evaluate_read([{"if-none-match", ~s("#{@etag}")}], meta()) ==
               :not_modified
    end

    test "* is not-modified for an existing object" do
      assert Conditional.evaluate_read([{"if-none-match", "*"}], meta()) == :not_modified
    end

    test "non-matching etag serves the object" do
      assert Conditional.evaluate_read([{"if-none-match", ~s("other")}], meta()) == :ok
    end
  end

  describe "read: date conditionals" do
    test "If-Modified-Since before last_modified serves the object" do
      headers = [{"if-modified-since", "Sun, 19 Jul 2026 12:00:00 GMT"}]
      assert Conditional.evaluate_read(headers, meta()) == :ok
    end

    test "If-Modified-Since at/after last_modified is not-modified" do
      headers = [{"if-modified-since", "Mon, 20 Jul 2026 12:00:00 GMT"}]
      assert Conditional.evaluate_read(headers, meta()) == :not_modified
    end

    test "sub-second last_modified is truncated, so the same second is not-modified" do
      m = meta(%{last_modified: ~U[2026-07-20 12:00:00.750000Z]})
      headers = [{"if-modified-since", "Mon, 20 Jul 2026 12:00:00 GMT"}]
      assert Conditional.evaluate_read(headers, m) == :not_modified
    end

    test "If-Unmodified-Since after last_modified serves the object" do
      headers = [{"if-unmodified-since", "Tue, 21 Jul 2026 12:00:00 GMT"}]
      assert Conditional.evaluate_read(headers, meta()) == :ok
    end

    test "If-Unmodified-Since before last_modified is a precondition failure" do
      headers = [{"if-unmodified-since", "Sun, 19 Jul 2026 12:00:00 GMT"}]
      assert Conditional.evaluate_read(headers, meta()) == :precondition_failed
    end

    test "an unparseable date is ignored (RFC 9110), not an error" do
      assert Conditional.evaluate_read([{"if-modified-since", "not a date"}], meta()) == :ok
      assert Conditional.evaluate_read([{"if-unmodified-since", "garbage"}], meta()) == :ok
    end

    test "a non-GMT zone is invalid, so the header is ignored rather than misread" do
      # Would be :precondition_failed if the zone were wrongly treated as UTC.
      headers = [{"if-unmodified-since", "Sun, 19 Jul 2026 12:00:00 +0200"}]
      assert Conditional.evaluate_read(headers, meta()) == :ok

      # Same for the not-modified direction: ignored, so the object is served.
      headers = [{"if-modified-since", "Mon, 20 Jul 2026 12:00:00 PST"}]
      assert Conditional.evaluate_read(headers, meta()) == :ok
    end
  end

  describe "repeated header lines (RFC 9110 §5.3)" do
    test "If-Match split across lines is treated as one comma-joined list" do
      headers = [{"if-match", ~s("other")}, {"if-match", ~s("#{@etag}")}]
      assert Conditional.evaluate_read(headers, meta()) == :ok
      assert Conditional.evaluate_write(headers, meta()) == :ok
    end

    test "If-None-Match split across lines still matches" do
      headers = [{"if-none-match", ~s("other")}, {"if-none-match", ~s("#{@etag}")}]
      assert Conditional.evaluate_read(headers, meta()) == :not_modified
      assert Conditional.evaluate_write(headers, meta()) == :precondition_failed
    end

    test "repeated lines that all miss still fail the precondition" do
      headers = [{"if-match", ~s("a")}, {"if-match", ~s("b")}]
      assert Conditional.evaluate_read(headers, meta()) == :precondition_failed
    end
  end

  describe "read: precedence (RFC 9110 §13.2.2)" do
    test "If-Match wins over If-Unmodified-Since" do
      # Date alone would fail; the matching etag takes precedence and serves.
      headers = [
        {"if-match", ~s("#{@etag}")},
        {"if-unmodified-since", "Sun, 19 Jul 2026 12:00:00 GMT"}
      ]

      assert Conditional.evaluate_read(headers, meta()) == :ok
    end

    test "If-None-Match wins over If-Modified-Since" do
      # Date alone would say not-modified; the non-matching etag takes precedence.
      headers = [
        {"if-none-match", ~s("other")},
        {"if-modified-since", "Mon, 20 Jul 2026 12:00:00 GMT"}
      ]

      assert Conditional.evaluate_read(headers, meta()) == :ok
    end

    test "a failed If-Match short-circuits before If-None-Match" do
      headers = [{"if-match", ~s("other")}, {"if-none-match", ~s("#{@etag}")}]
      assert Conditional.evaluate_read(headers, meta()) == :precondition_failed
    end
  end

  describe "write: If-None-Match (create-if-absent)" do
    test "* on an absent key allows the write" do
      assert Conditional.evaluate_write([{"if-none-match", "*"}], nil) == :ok
    end

    test "* on an existing key is a precondition failure" do
      assert Conditional.evaluate_write([{"if-none-match", "*"}], meta()) == :precondition_failed
    end

    test "a specific etag that matches blocks the write" do
      assert Conditional.evaluate_write([{"if-none-match", ~s("#{@etag}")}], meta()) ==
               :precondition_failed
    end

    test "a specific etag that does not match allows the write" do
      assert Conditional.evaluate_write([{"if-none-match", ~s("other")}], meta()) == :ok
    end
  end

  describe "write: If-Match (compare-and-swap)" do
    test "matching etag allows the overwrite" do
      assert Conditional.evaluate_write([{"if-match", ~s("#{@etag}")}], meta()) == :ok
    end

    test "non-matching etag is a precondition failure" do
      assert Conditional.evaluate_write([{"if-match", ~s("stale")}], meta()) ==
               :precondition_failed
    end

    test "an absent key is a 404, not a precondition failure" do
      assert Conditional.evaluate_write([{"if-match", ~s("#{@etag}")}], nil) == :not_found
    end
  end

  describe "write_conditions?/1" do
    test "true only when a write precondition is present" do
      assert Conditional.write_conditions?([{"if-match", "*"}])
      assert Conditional.write_conditions?([{"if-none-match", "*"}])
      refute Conditional.write_conditions?([{"if-modified-since", "whenever"}])
      refute Conditional.write_conditions?([{"content-type", "text/plain"}])
      refute Conditional.write_conditions?([])
    end
  end

  describe "no headers" do
    test "an unconditional read always serves" do
      assert Conditional.evaluate_read([], meta()) == :ok
    end

    test "an unconditional write always proceeds" do
      assert Conditional.evaluate_write([], meta()) == :ok
      assert Conditional.evaluate_write([], nil) == :ok
    end
  end
end
