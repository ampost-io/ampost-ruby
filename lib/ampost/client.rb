# frozen_string_literal: true

require "date"
require "json"
require "securerandom"
require "uri"

module Ampost
  DEFAULT_BASE_URL = "https://api.ampost.io"

  # The Ampost API client.
  #
  #   client = Ampost::Client.new # reads AMPOST_API_KEY
  #   post = client.posts.create({ text: "Hello", targets: [{ platforms: ["bluesky"] }], publishNow: true })
  #
  # Each tag of the API is a reader (`posts`, `accounts`, `platform_sets`, `media`, `analytics`,
  # `webhooks`, `platforms`, `docs`, `feedback`) with one method per operation. Request bodies are
  # Hashes with the API's field names (symbol or string keys); responses are Hashes with string keys.
  # A client holds no connection, so one client can serve many threads.
  class Client
    include Resources::Readers

    # Per-call options every method takes as keyword arguments.
    REQUEST_OPTIONS = %i[timeout max_retries extra_headers].freeze
    # Operations that take an `Idempotency-Key` also take `idempotency_key:`.
    IDEMPOTENT_OPTIONS = (REQUEST_OPTIONS + %i[idempotency_key]).freeze

    # @return [String]
    attr_reader :base_url
    # @return [Integer] retries after a 429, a 5xx or a network error (see README, "Retries")
    attr_reader :max_retries
    # @return [Numeric] seconds per attempt
    attr_reader :timeout
    # @return [Numeric] a longer `Retry-After` is not waited for: the error is raised
    attr_reader :max_retry_delay

    # @param api_key [String, nil] An API key from https://ampost.io/app/settings/api-keys. Default: `AMPOST_API_KEY`.
    # @param base_url [String, nil] Default: `AMPOST_BASE_URL`, else `https://api.ampost.io`.
    # @param max_retries [Integer] Retries after a 429, a 5xx or a network error.
    # @param timeout [Numeric] Seconds per attempt.
    # @param max_retry_delay [Numeric] A longer `Retry-After` is not waited for: the error is raised.
    # @param default_headers [Hash{String => String}] Headers sent with every request.
    # @param transport [#call] The HTTP layer; default Ampost::Transport::NetHTTP.
    def initialize(api_key: nil, base_url: nil, max_retries: 2, timeout: 60, max_retry_delay: 60,
                   default_headers: {}, transport: nil)
      api_key = blank_to_nil(api_key) || blank_to_nil(ENV.fetch("AMPOST_API_KEY", nil))
      unless api_key
        raise Error, "Missing API key: pass api_key: or set AMPOST_API_KEY. " \
                     "Create one at https://ampost.io/app/settings/api-keys?ref=github"
      end

      @api_key = api_key
      @base_url = (blank_to_nil(base_url) || blank_to_nil(ENV.fetch("AMPOST_BASE_URL", nil)) || DEFAULT_BASE_URL).chomp("/")
      @max_retries = max_retries
      @timeout = timeout
      @max_retry_delay = max_retry_delay
      @default_headers = default_headers.to_h
      @transport = transport || Transport::NetHTTP.new
      init_resources
      @media = MediaResource.new(self)
    end

    # Never shows the key.
    def inspect
      "#<#{self.class.name} base_url=#{@base_url.inspect}>"
    end
    alias to_s inspect

    # Sends one API call with auth, the idempotency key and retries. The generated methods call this.
    #
    # @param method [String] the HTTP method
    # @param path [String] the path, already encoded
    # @param query [Hash{String => Object}] nil values are left out
    # @param body [Hash, nil] sent as JSON
    # @param idempotent [Boolean] the operation takes an `Idempotency-Key`
    # @param options [Hash] `timeout:`, `max_retries:`, `extra_headers:`, and `idempotency_key:` when idempotent
    # @return [Hash, Array, nil] the parsed JSON response
    def request(method, path, query: nil, body: nil, idempotent: false, options: {})
      check_options(options, idempotent)
      request = build_request(method, path, query, body, idempotent, options)
      # Without a key, a write that timed out may have been done: only reads and keyed writes repeat.
      repeatable = method == "GET" || idempotent
      max_retries = options.fetch(:max_retries, @max_retries)
      attempt = 0
      loop do
        begin
          response = @transport.call(request)
        rescue APIConnectionError
          raise if !repeatable || attempt >= max_retries

          sleep_for(backoff(attempt))
          attempt += 1
          next
        end
        return parse(response) if response.success?

        error = APIError.from_response(response)
        delay = retry_delay(error, attempt, repeatable)
        raise error if delay.nil? || attempt >= max_retries

        sleep_for(delay)
        attempt += 1
      end
    end

    # Like #request for a list operation: returns its first Page.
    #
    # @return [Ampost::Page]
    def paginate(method, path, query: nil, options: {})
      fetch = lambda do |offset|
        request(method, path, query: (query || {}).merge("offset" => offset), options: options)
      end
      Page.new(request(method, path, query: query, options: options), fetch)
    end

    # One request outside the API (the media PUT): no auth header, no retries.
    #
    # @return [Ampost::Transport::Response]
    def send_raw(method, url, headers:, body:, timeout:)
      @transport.call(Transport::Request.new(method: method, url: url, headers: headers, body: body, timeout: timeout))
    end

    private

    def check_options(options, idempotent)
      unknown = options.keys - (idempotent ? IDEMPOTENT_OPTIONS : REQUEST_OPTIONS)
      return if unknown.empty?

      raise ArgumentError, "unknown keyword#{"s" if unknown.size > 1}: #{unknown.map(&:inspect).join(", ")} " \
                           "(pass the request body as a Hash: method({ ... }))"
    end

    def build_request(method, path, query, body, idempotent, options)
      headers = {
        "Accept" => "application/json",
        "User-Agent" => "ampost-ruby/#{VERSION}"
      }
      headers.merge!(@default_headers.transform_keys(&:to_s))
      headers.merge!(options.fetch(:extra_headers, {}).to_h.transform_keys(&:to_s))
      headers.delete_if { |name, _| name.casecmp?("authorization") }
      headers["Authorization"] = "Bearer #{@api_key}"
      payload = nil
      unless body.nil?
        headers["Content-Type"] = "application/json"
        payload = JSON.generate(json_value(body))
      end
      headers["Idempotency-Key"] = options[:idempotency_key] || SecureRandom.uuid if idempotent
      Transport::Request.new(
        method: method,
        url: "#{@base_url}#{path}#{query_string(query)}",
        headers: headers,
        body: payload,
        timeout: options.fetch(:timeout, @timeout)
      )
    end

    def query_string(query)
      pairs = (query || {}).reject { |_, value| value.nil? }.map { |name, value| [name.to_s, query_value(value)] }
      pairs.empty? ? "" : "?#{URI.encode_www_form(pairs)}"
    end

    def query_value(value)
      case value
      when Array then value.map { |item| query_value(item) }
      when Time, Date then value.iso8601
      else value.to_s
      end
    end

    # Times and dates become ISO 8601 strings; everything else goes to JSON as is.
    def json_value(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_s, json_value(v)] }
      when Array then value.map { |item| json_value(item) }
      when Time, Date then value.iso8601
      else value
      end
    end

    # Seconds to wait before retrying, or nil to give up.
    def retry_delay(error, attempt, repeatable)
      retryable = error.status == 429 || # refused before anything ran
                  error.code == "IDEMPOTENCY_REQUEST_IN_PROGRESS" || # the first request with this key still runs
                  ((error.status >= 500 || error.status == 408) && repeatable)
      return nil unless retryable

      retry_after = Ampost.parse_retry_after(error.headers["retry-after"])
      return backoff(attempt) if retry_after.nil?

      # A quota reset days away is not worth blocking on.
      retry_after <= @max_retry_delay ? retry_after : nil
    end

    # Exponential backoff with jitter: about 0.5 s, 1 s, 2 s, ... up to 8 s.
    def backoff(attempt)
      [0.5 * (2**attempt), 8.0].min * (0.75 + (rand * 0.5))
    end

    def sleep_for(seconds)
      sleep(seconds)
    end

    def parse(response)
      return nil if response.body.nil? || response.body.empty?

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "Expected JSON from the API, got: #{response.body[0, 200]}"
    end

    def blank_to_nil(value)
      value.nil? || value.to_s.strip.empty? ? nil : value.to_s
    end
  end
end
