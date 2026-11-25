# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "ampost"

# The real key for test/smoke_test.rb, read before the unit tests clear the environment. An empty value
# counts as unset: GitHub Actions sets a missing secret to "", which Ruby treats as true.
SMOKE_API_KEY = ENV["AMPOST_API_KEY"].then { |v| v unless v.nil? || v.empty? }
SMOKE_BASE_URL = ENV["AMPOST_BASE_URL"].then { |v| v unless v.nil? || v.empty? }

# A mock API: answers each request with the next queued answer (a Response, an exception to raise, or a
# lambda taking the request) and records the requests.
class FakeTransport
  attr_reader :requests

  def initialize(*answers)
    @answers = answers
    @requests = []
  end

  def call(request)
    @requests << request
    raise Minitest::Assertion, "Unexpected request: #{request.method} #{request.url}" if @answers.empty?

    answer = @answers.shift
    answer = answer.call(request) if answer.is_a?(Proc)
    raise answer if answer.is_a?(Exception)

    answer
  end

  def last
    @requests.last
  end

  def bodies
    @requests.map { |r| r.body && JSON.parse(r.body) }
  end
end

module Helpers
  def json_response(body, status = 200, headers = {})
    Ampost::Transport::Response.new(status: status, headers: { "content-type" => "application/json" }.merge(headers),
                                    body: JSON.generate(body))
  end

  def text_response(status, text = "")
    Ampost::Transport::Response.new(status: status, headers: {}, body: text)
  end

  def api_error(status, code, message = "nope", headers = {})
    json_response({ error: { code: code, message: message, details: { field: "x" } } }, status, headers)
  end

  def page(items, offset = 0, total = nil, has_more = nil)
    total ||= items.size
    has_more = offset + items.size < total if has_more.nil?
    json_response({ data: items, pagination: { limit: 2, offset: offset, total: total, hasMore: has_more } })
  end

  # A client on `transport` that records its waits in `sleeps` instead of sleeping.
  def client(transport, **kwargs)
    kwargs[:api_key] = "amp_test" unless kwargs.key?(:api_key)
    client = Ampost::Client.new(transport: transport, **kwargs)
    waits = sleeps
    client.define_singleton_method(:sleep_for) { |seconds| waits << seconds }
    client
  end

  def sleeps
    @sleeps ||= []
  end

  def query_params(request)
    query = URI(request.url).query
    query ? URI.decode_www_form(query) : []
  end
end

class AmpostTest < Minitest::Test
  include Helpers

  def setup
    @saved_env = ENV.to_h.slice("AMPOST_API_KEY", "AMPOST_BASE_URL")
    ENV.delete("AMPOST_API_KEY")
    ENV.delete("AMPOST_BASE_URL")
  end

  def teardown
    ENV.delete("AMPOST_API_KEY")
    ENV.delete("AMPOST_BASE_URL")
    @saved_env.each { |name, value| ENV[name] = value }
  end
end
