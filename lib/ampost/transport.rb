# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module Ampost
  # The HTTP layer under the client. The default, NetHTTP, uses only the standard library; pass your
  # own object with the same `call(request)` to `Ampost::Client.new(transport:)` to change it
  # (instrumentation, a custom HTTP library, tests).
  module Transport
    # One HTTP request. `headers` has the exact names to send; `body` is a String or nil.
    Request = Struct.new(:method, :url, :headers, :body, :timeout, keyword_init: true)

    # One HTTP response. `headers` has lowercase names.
    Response = Struct.new(:status, :headers, :body, keyword_init: true) do
      def success?
        status >= 200 && status < 300
      end
    end

    # Net::HTTP, one connection per request (so a client is safe to share between threads). Proxies
    # come from `http_proxy` / `https_proxy` as usual for Net::HTTP.
    class NetHTTP
      # Errors that mean no usable response arrived.
      CONNECTION_ERRORS = [
        SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse,
        Net::ProtocolError
      ].freeze

      # @param request [Request]
      # @return [Response]
      # @raise [Ampost::APITimeoutError, Ampost::APIConnectionError] when no response arrives
      def call(request)
        uri = URI(request.url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = request.timeout
        http.read_timeout = request.timeout
        http.write_timeout = request.timeout
        http.ssl_timeout = request.timeout if http.use_ssl?
        response = http.start do |connection|
          connection.send_request(request.method, uri.request_uri, request.body, request.headers)
        end
        headers = {}
        response.each_header { |name, value| headers[name] = value }
        body = response.body.to_s.dup.force_encoding(Encoding::UTF_8)
        Response.new(status: response.code.to_i, headers: headers, body: body)
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
        raise APITimeoutError, "Request timed out after #{request.timeout} s"
      rescue *CONNECTION_ERRORS => e
        raise APIConnectionError, "Connection error: #{e.message} (#{e.class})"
      end
    end
  end
end
