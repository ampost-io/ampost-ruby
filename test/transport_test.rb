# frozen_string_literal: true

require "socket"
require "test_helper"

# The default Net::HTTP transport against a one-shot HTTP server on localhost (no network).
class NetHTTPTransportTest < AmpostTest
  def serve(response = nil, &handler)
    server = TCPServer.new("127.0.0.1", 0)
    @received = Queue.new
    @thread = Thread.new do
      socket = server.accept
      head = +""
      head << socket.readline until head.end_with?("\r\n\r\n")
      length = head[/^content-length: *(\d+)/i, 1].to_i
      @received << [head, socket.read(length)]
      handler ? handler.call(socket) : socket.write(response)
      socket.close
    rescue IOError, SystemCallError
      nil
    ensure
      server.close
    end
    "http://127.0.0.1:#{server.addr[1]}"
  end

  def http_response(status, body, headers = {})
    head = { "Content-Type" => "application/json", "Content-Length" => body.bytesize, "Connection" => "close" }.merge(headers)
    "HTTP/1.1 #{status}\r\n#{head.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n#{body}"
  end

  def teardown
    @thread&.kill&.join
    super
  end

  def test_sends_the_request_and_reads_the_response
    base = serve(http_response("201 Created", JSON.generate({ id: "p1", ok: "é" })))
    c = Ampost::Client.new(api_key: "amp_live", base_url: base)
    result = c.posts.create({ text: "Grüße" }, idempotency_key: "k1")
    assert_equal({ "id" => "p1", "ok" => "é" }, result)
    head, body = @received.pop
    assert_match(%r{\APOST /api/posts HTTP/1.1\r\n}, head)
    assert_match(/^Authorization: Bearer amp_live\r$/, head)
    assert_match(/^Idempotency-Key: k1\r$/, head)
    assert_match(/^User-Agent: ampost-ruby\/#{Regexp.escape(Ampost::VERSION)}\r$/, head)
    assert_equal({ "text" => "Grüße" }, JSON.parse(body.force_encoding("utf-8")))
  end

  def test_sends_the_query_and_raises_typed_errors_with_headers
    body = JSON.generate({ error: { code: "POST_NOT_FOUND", message: "Gone" } })
    base = serve(http_response("404 Not Found", body, "X-Request-Id" => "req_404"))
    error = assert_raises(Ampost::NotFoundError) do
      Ampost::Client.new(api_key: "k", base_url: base, max_retries: 0).posts.list(status: "failed", limit: 1)
    end
    assert_equal %w[POST_NOT_FOUND Gone req_404], [error.code, error.api_message, error.request_id]
    head, = @received.pop
    assert_match(%r{\AGET /api/posts\?status=failed&limit=1 HTTP/1.1\r\n}, head)
  end

  def test_times_out
    base = serve { |_socket| sleep 2 }
    error = assert_raises(Ampost::APITimeoutError) do
      Ampost::Client.new(api_key: "k", base_url: base, max_retries: 0, timeout: 0.2).posts.get("p1")
    end
    assert_match(/timed out after 0.2 s/, error.message)
  end

  def test_connection_refused_is_a_connection_error
    port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
    error = assert_raises(Ampost::APIConnectionError) do
      Ampost::Client.new(api_key: "k", base_url: "http://127.0.0.1:#{port}", max_retries: 0).posts.get("p1")
    end
    refute_kind_of Ampost::APITimeoutError, error
  end
end
