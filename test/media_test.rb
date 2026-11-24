# frozen_string_literal: true

require "pathname"
require "stringio"
require "tmpdir"
require "test_helper"

class MediaTest < AmpostTest
  CREATED = {
    "id" => "up_1",
    "status" => "pending",
    "uploadPageUrl" => "https://ampost.io/upload/up_1#secret",
    "uploadUrl" => "https://storage.example.com/put/up_1",
    "method" => "PUT",
    "headers" => { "x-upload-token" => "tok" },
    "limits" => { "maxFiles" => 1, "maxSizeBytes" => 1000, "mimeTypes" => ["image/png"] },
    "createdAt" => "2026-11-22T00:00:00Z",
    "expiresAt" => "2026-11-22T01:00:00Z"
  }.freeze
  FILE = {
    "url" => "https://cdn.example.com/a.png", "type" => "image", "mimeType" => "image/png", "sizeBytes" => 3,
    "width" => 1, "height" => 1, "durationSeconds" => nil
  }.freeze

  def status(state, files: [], error: nil)
    json_response({ id: "up_1", status: state, files: files, createdAt: "", expiresAt: "", completedAt: nil, error: error })
  end

  def test_creates_puts_the_bytes_with_the_given_headers_only_and_waits
    api = FakeTransport.new(json_response(CREATED), text_response(200), status("pending"), status("completed", files: [FILE.merge("extra" => 1)]))
    media = client(api).media.upload(StringIO.new("png"), file_name: "a.png", poll_interval: 0.5)
    assert_equal FILE, media
    create, put, *polls = api.requests
    assert_equal({ "fileName" => "a.png" }, JSON.parse(create.body))
    assert_equal "PUT", put.method
    assert_equal CREATED["uploadUrl"], put.url
    assert_equal "png", put.body
    assert_equal({ "x-upload-token" => "tok", "x-content-type" => "image/png" }, put.headers)
    assert_equal 900, put.timeout
    assert_equal ["https://api.ampost.io/api/media/uploads/up_1"] * 2, polls.map(&:url)
    assert_equal [0.5], sleeps
  end

  def test_reads_a_path_and_takes_the_name_and_type_from_it
    Dir.mktmpdir do |dir|
      path = File.join(dir, "launch.mp4")
      File.binwrite(path, "\x00\x01".b)
      api = FakeTransport.new(json_response(CREATED), text_response(200), status("completed", files: [FILE]))
      client(api).media.upload(path)
      assert_equal({ "fileName" => "launch.mp4" }, JSON.parse(api.requests[0].body))
      assert_equal "video/mp4", api.requests[1].headers["x-content-type"]
      assert_equal "\x00\x01".b, api.requests[1].body
    end
  end

  def test_takes_a_pathname_and_a_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "photo.JPG")
      File.binwrite(path, "jpg")
      api = FakeTransport.new(json_response(CREATED), text_response(200), status("completed", files: [FILE]),
                              json_response(CREATED), text_response(200), status("completed", files: [FILE]))
      client(api).media.upload(Pathname(path))
      File.open(path, "rb") { |file| client(api).media.upload(file) }
      assert_equal [{ "fileName" => "photo.JPG" }] * 2, [api.requests[0], api.requests[3]].map { |r| JSON.parse(r.body) }
      assert_equal ["image/jpeg"] * 2, [api.requests[1], api.requests[4]].map { |r| r.headers["x-content-type"] }
    end
  end

  def test_refuses_an_unknown_type_before_calling_the_api
    api = FakeTransport.new
    error = assert_raises(Ampost::Error) { client(api).media.upload(StringIO.new("x"), file_name: "notes.txt") }
    assert_match(/content_type/, error.message)
    assert_raises(ArgumentError) { client(api).media.upload(42) }
    assert_empty api.requests
  end

  def test_an_explicit_content_type_wins
    api = FakeTransport.new(json_response(CREATED), text_response(200), status("completed", files: [FILE]))
    client(api).media.upload(StringIO.new("x"), content_type: "image/png")
    assert_equal({ "fileName" => "file" }, JSON.parse(api.requests[0].body))
    assert_equal "image/png", api.requests[1].headers["x-content-type"]
  end

  def test_raises_when_ampost_refuses_the_file
    api = FakeTransport.new(json_response(CREATED), text_response(200), status("failed", error: "not an image"))
    error = assert_raises(Ampost::MediaUploadError) { client(api).media.upload(StringIO.new("x"), file_name: "a.png") }
    assert_match(/not an image/, error.message)
    assert_equal %w[failed up_1], [error.reason, error.upload_id]
  end

  def test_raises_when_storage_rejects_the_put
    api = FakeTransport.new(json_response(CREATED), text_response(403, "denied"))
    error = assert_raises(Ampost::MediaUploadError) { client(api).media.upload(StringIO.new("x"), file_name: "a.png") }
    assert_match(/403 denied/, error.message)
    assert_equal "upload_rejected", error.reason
  end

  def test_gives_up_waiting_after_wait_timeout
    api = FakeTransport.new(json_response(CREATED), text_response(200), status("pending"))
    error = assert_raises(Ampost::MediaUploadError) do
      client(api).media.upload(StringIO.new("x"), file_name: "a.png", poll_interval: 5, wait_timeout: 1)
    end
    assert_equal "timeout", error.reason
  end

  def test_expired
    api = FakeTransport.new(status("expired"))
    error = assert_raises(Ampost::MediaUploadError) { client(api).media.wait_for_upload("up_1") }
    assert_equal "expired", error.reason
  end

  def test_completed_without_a_file
    api = FakeTransport.new(json_response(CREATED), text_response(200), status("completed"))
    error = assert_raises(Ampost::MediaUploadError) { client(api).media.upload(StringIO.new("x"), file_name: "a.png") }
    assert_equal "failed", error.reason
  end

  def test_guesses_common_types
    {
      "a.JPG" => "image/jpeg", "b.webp" => "image/webp", "c.mov" => "video/quicktime", "d.webm" => "video/webm",
      "e" => nil, "f.txt" => nil
    }.each do |name, expected|
      assert_equal expected, Ampost::MediaResource.guess_content_type(name), name if expected
      assert_nil Ampost::MediaResource.guess_content_type(name), name unless expected
    end
  end
end
