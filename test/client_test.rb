# frozen_string_literal: true

require "test_helper"

POST = { "id" => "p1", "status" => "draft" }.freeze
CREATE = { text: "Hi", targets: [{ platforms: ["bluesky"] }] }.freeze

class RequestsTest < AmpostTest
  def test_sends_the_key_as_bearer_json_and_user_agent
    api = FakeTransport.new(json_response(POST))
    result = client(api).posts.create({ text: "Hi", targets: [{ platforms: %w[bluesky threads] }] })
    assert_equal POST, result
    request = api.last
    assert_equal "POST", request.method
    assert_equal "https://api.ampost.io/api/posts", request.url
    assert_equal "Bearer amp_test", request.headers["Authorization"]
    assert_equal "application/json", request.headers["Content-Type"]
    assert_equal "application/json", request.headers["Accept"]
    assert_equal "ampost-ruby/#{Ampost::VERSION}", request.headers["User-Agent"]
    assert_equal({ "text" => "Hi", "targets" => [{ "platforms" => %w[bluesky threads] }] }, JSON.parse(request.body))
  end

  def test_takes_string_keys_and_serializes_times
    api = FakeTransport.new(json_response(POST))
    client(api).posts.create({ "text" => "Hi", "scheduledFor" => Time.utc(2026, 12, 1, 9), "targets" => [] })
    assert_equal({ "text" => "Hi", "scheduledFor" => "2026-12-01T09:00:00Z", "targets" => [] }, JSON.parse(api.last.body))
  end

  def test_serializes_the_query_and_leaves_out_nil
    api = FakeTransport.new(page([]))
    client(api).posts.list(status: "failed", platform_set_id: "set 1", limit: 5)
    assert_equal [%w[status failed], ["platformSetId", "set 1"], %w[limit 5]], query_params(api.last)
  end

  def test_maps_ruby_names_and_dates
    api = FakeTransport.new(page([]), json_response({ "data" => [] }))
    client(api).analytics.list_followers(from: Date.new(2026, 11, 1), to: "2026-11-02")
    assert_equal [%w[from 2026-11-01], %w[to 2026-11-02]], query_params(api.requests[0])
    client(api).platform_sets.get_queue_slots("s1", count: 3, filter: "free")
    assert_equal [%w[count 3], %w[filter free]], query_params(api.requests[1])
  end

  def test_encodes_path_parameters
    api = FakeTransport.new(json_response(POST))
    client(api).posts.get("a/b c")
    assert_equal "https://api.ampost.io/api/posts/a%2Fb%20c", api.last.url
  end

  def test_rejects_an_empty_path_parameter
    api = FakeTransport.new
    assert_raises(ArgumentError) { client(api).posts.get("") }
    assert_raises(ArgumentError) { client(api).posts.get(nil) }
    assert_empty api.requests
  end

  def test_rejects_unknown_options_such_as_a_body_without_braces
    api = FakeTransport.new
    error = assert_raises(ArgumentError) { client(api).posts.update("p1", text: "x") }
    assert_match(/unknown keyword: :text/, error.message)
    assert_raises(ArgumentError) { client(api).posts.update("p1", { text: "x" }, idempotency_key: "k") }
    assert_empty api.requests
  end

  def test_reads_key_and_base_url_from_the_environment
    ENV["AMPOST_API_KEY"] = "amp_env"
    ENV["AMPOST_BASE_URL"] = "http://localhost:3000/"
    api = FakeTransport.new(json_response(POST))
    Ampost::Client.new(transport: api).posts.get("p1")
    assert_equal "http://localhost:3000/api/posts/p1", api.last.url
    assert_equal "Bearer amp_env", api.last.headers["Authorization"]
  end

  def test_base_url_option_wins_over_the_environment
    ENV["AMPOST_BASE_URL"] = "http://localhost:3000"
    api = FakeTransport.new(json_response(POST))
    client(api, base_url: "https://staging.example.com/").posts.get("p1")
    assert_equal "https://staging.example.com/api/posts/p1", api.last.url
  end

  def test_refuses_to_start_without_a_key
    error = assert_raises(Ampost::Error) { Ampost::Client.new }
    assert_match(/AMPOST_API_KEY/, error.message)
  end

  def test_does_not_show_the_key
    c = client(FakeTransport.new, api_key: "amp_secret_value")
    refute_includes c.inspect, "amp_secret_value"
    refute_includes c.to_s, "amp_secret_value"
  end

  def test_extra_headers_cannot_replace_auth
    api = FakeTransport.new(json_response(POST))
    client(api, default_headers: { "X-App" => "a" }).posts.get("p1", extra_headers: { "X-Trace" => "1", "authorization" => "Bearer other" })
    assert_equal "1", api.last.headers["X-Trace"]
    assert_equal "a", api.last.headers["X-App"]
    assert_equal "Bearer amp_test", api.last.headers["Authorization"]
    assert_equal ["Authorization"], api.last.headers.keys.grep(/authorization/i)
  end

  def test_returns_nil_for_an_empty_body
    api = FakeTransport.new(text_response(204))
    assert_nil client(api).webhooks.delete("w1")
  end

  def test_raises_on_a_non_json_success
    api = FakeTransport.new(text_response(200, "<html>"))
    error = assert_raises(Ampost::Error) { client(api).posts.get("p1") }
    assert_match(/Expected JSON/, error.message)
  end
end

class IdempotencyTest < AmpostTest
  def test_generates_a_key_and_keeps_it_across_retries
    api = FakeTransport.new(api_error(503, "INTERNAL_ERROR"), json_response(POST))
    client(api).posts.create(CREATE)
    keys = api.requests.map { |r| r.headers["Idempotency-Key"] }
    assert_equal 2, keys.size
    assert_equal keys[0], keys[1]
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, keys[0])
  end

  def test_sends_the_callers_key
    api = FakeTransport.new(json_response(POST))
    client(api).posts.create(CREATE, idempotency_key: "release-v1.4.0")
    assert_equal "release-v1.4.0", api.last.headers["Idempotency-Key"]
  end

  def test_gives_each_call_its_own_key
    api = FakeTransport.new(json_response(POST), json_response(POST))
    c = client(api)
    c.posts.publish("p1")
    c.posts.publish("p1")
    refute_equal api.requests[0].headers["Idempotency-Key"], api.requests[1].headers["Idempotency-Key"]
  end

  def test_sends_no_key_on_other_operations
    api = FakeTransport.new(json_response(POST))
    client(api).posts.update("p1", { text: "x" })
    refute api.last.headers.key?("Idempotency-Key")
  end

  def test_waits_while_the_first_request_with_the_key_runs
    api = FakeTransport.new(api_error(409, "IDEMPOTENCY_REQUEST_IN_PROGRESS", "busy", "retry-after" => "1"), json_response(POST))
    assert_equal POST, client(api).posts.create(CREATE)
    assert_equal [1.0], sleeps
  end
end

class RetriesTest < AmpostTest
  def test_retries_a_429_after_retry_after_even_for_a_write_without_a_key
    api = FakeTransport.new(api_error(429, "RATE_LIMITED", "slow down", "retry-after" => "3"), json_response(POST))
    assert_equal POST, client(api).posts.update("p1", { text: "x" })
    assert_equal 2, api.requests.size
    assert_equal [3.0], sleeps
  end

  def test_does_not_wait_for_a_long_retry_after
    api = FakeTransport.new(api_error(429, "QUOTA_EXCEEDED", "quota", "retry-after" => "86400"))
    error = assert_raises(Ampost::RateLimitError) { client(api).posts.get("p1") }
    assert_equal 86_400.0, error.retry_after
    assert_equal "QUOTA_EXCEEDED", error.code
    assert_empty sleeps
  end

  def test_retries_a_5xx_on_a_get_with_backoff
    api = FakeTransport.new(api_error(502, "PLATFORM_REQUEST_FAILED"), api_error(500, "INTERNAL_ERROR"), json_response(POST))
    assert_equal POST, client(api).posts.get("p1")
    assert_equal 2, sleeps.size
    assert_includes 0.375..0.625, sleeps[0]
    assert_includes 0.75..1.25, sleeps[1]
  end

  def test_does_not_repeat_a_write_without_a_key_after_a_5xx
    api = FakeTransport.new(api_error(500, "INTERNAL_ERROR"))
    assert_raises(Ampost::InternalServerError) { client(api).posts.update("p1", { text: "x" }) }
    assert_equal 1, api.requests.size
  end

  def test_retries_network_errors_on_reads_then_gives_up
    error = Ampost::APIConnectionError.new("Connection error: refused")
    api = FakeTransport.new(error, error, error)
    raised = assert_raises(Ampost::APIConnectionError) { client(api).posts.get("p1") }
    assert_match(/refused/, raised.message)
    assert_equal 3, api.requests.size
    assert_equal 2, sleeps.size
  end

  def test_retries_network_errors_on_keyed_writes
    api = FakeTransport.new(Ampost::APIConnectionError.new("reset"), json_response(POST))
    assert_equal POST, client(api).posts.create(CREATE)
    assert_equal 1, api.requests.map { |r| r.headers["Idempotency-Key"] }.uniq.size
  end

  def test_honours_max_retries_per_request_and_per_client
    api = FakeTransport.new(api_error(503, "INTERNAL_ERROR"), api_error(503, "INTERNAL_ERROR"))
    assert_raises(Ampost::InternalServerError) { client(api).posts.get("p1", max_retries: 0) }
    assert_equal 1, api.requests.size
    assert_raises(Ampost::InternalServerError) { client(api, max_retries: 0).posts.get("p1") }
    assert_equal 2, api.requests.size
  end

  def test_passes_the_timeout
    api = FakeTransport.new(json_response(POST), json_response(POST))
    c = client(api, timeout: 5)
    c.posts.get("p1", timeout: 1.5)
    c.posts.get("p1")
    assert_equal [1.5, 5], api.requests.map(&:timeout)
  end
end

ERRORS = {
  400 => Ampost::BadRequestError,
  401 => Ampost::AuthenticationError,
  403 => Ampost::PermissionDeniedError,
  404 => Ampost::NotFoundError,
  409 => Ampost::ConflictError,
  413 => Ampost::PayloadTooLargeError,
  422 => Ampost::UnprocessableEntityError,
  429 => Ampost::RateLimitError,
  500 => Ampost::InternalServerError,
  418 => Ampost::APIError
}.freeze

class ErrorsTest < AmpostTest
  ERRORS.each do |status, error_class|
    define_method("test_maps_#{status}_to_#{error_class.name.split("::").last}") do
      api = FakeTransport.new(api_error(status, "SOME_CODE", "Something is off", "X-Request-Id" => "req_1"))
      error = assert_raises(error_class) { client(api, max_retries: 0).posts.get("p1") }
      assert_instance_of error_class, error
      assert_kind_of Ampost::Error, error
      assert_equal [status, "SOME_CODE", "Something is off"], [error.status, error.code, error.api_message]
      assert_equal({ "field" => "x" }, error.details)
      assert_equal "req_1", error.request_id
      assert_equal "#{status} SOME_CODE: Something is off", error.message
    end
  end

  def test_reads_string_errors_and_non_json_bodies
    api = FakeTransport.new(json_response({ error: "Unauthorized" }, 401), text_response(400, "Bad gateway"))
    c = client(api)
    error = assert_raises(Ampost::AuthenticationError) { c.posts.get("p1") }
    assert_equal %w[HTTP_401 Unauthorized], [error.code, error.api_message]
    error = assert_raises(Ampost::BadRequestError) { c.posts.get("p1") }
    assert_match(/Bad gateway/, error.message)
  end

  def test_parses_an_http_date_retry_after
    api = FakeTransport.new(api_error(429, "RATE_LIMITED", "slow", "retry-after" => "Wed, 21 Oct 2015 07:28:00 GMT"), json_response(POST))
    assert_equal POST, client(api).posts.get("p1")
    assert_equal [0.0], sleeps
  end

  def test_parse_retry_after
    assert_nil Ampost.parse_retry_after(nil)
    assert_nil Ampost.parse_retry_after("soon")
    assert_equal 2.5, Ampost.parse_retry_after(" 2.5 ")
    assert_in_delta 30, Ampost.parse_retry_after((Time.now + 30).httpdate), 2
  end

  def test_raises_api_timeout_error
    api = FakeTransport.new(Ampost::APITimeoutError.new("Request timed out after 60 s"))
    assert_raises(Ampost::APITimeoutError) { client(api, max_retries: 0).posts.get("p1") }
  end

  def test_timeouts_of_writes_without_a_key_are_not_repeated
    api = FakeTransport.new(Ampost::APITimeoutError.new("Request timed out after 60 s"))
    assert_raises(Ampost::APITimeoutError) { client(api).posts.update("p1", { text: "x" }) }
    assert_equal 1, api.requests.size
  end
end
