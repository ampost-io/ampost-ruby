# frozen_string_literal: true

require "json"
require "time"

module Ampost
  # Base class of every error the SDK raises.
  class Error < StandardError; end

  # The API answered with an error status.
  #
  # The body is `{"error": {"code", "message", "details"}}`: `code` is stable (for example
  # `VALIDATION_FAILED`, `POST_NOT_FOUND`); the full list is at https://ampost.io/docs?ref=github#errors.
  # `message` is `"<status> <code>: <api_message>"`.
  class APIError < Error
    # @return [Integer] the HTTP status
    attr_reader :status
    # @return [String] the stable error code, or `HTTP_<status>` when the body has none
    attr_reader :code
    # @return [String] the API's message
    attr_reader :api_message
    # @return [Hash, nil] more about the error, for example `"issues"` for a 400
    attr_reader :details
    # @return [Hash{String => String}] the response headers, with lowercase names
    attr_reader :headers
    # @return [String, nil] `X-Request-Id`: quote it when you contact support
    attr_reader :request_id

    def initialize(status, code, api_message, details, headers)
      super("#{status} #{code}: #{api_message}")
      @status = status
      @code = code
      @api_message = api_message
      @details = details
      @headers = headers.to_h.transform_keys { |name| name.to_s.downcase }
      @request_id = @headers["x-request-id"]
    end

    # Builds the subclass for the status from a response.
    #
    # @param response [Ampost::Transport::Response]
    # @return [APIError]
    def self.from_response(response)
      code, api_message, details = parse_body(response)
      Ampost.error_class(response.status).new(response.status, code, api_message, details, response.headers)
    end

    def self.parse_body(response)
      fallback_code = "HTTP_#{response.status}"
      fallback_message = "Request failed"
      text = response.body.to_s
      begin
        body = JSON.parse(text)
      rescue JSON::ParserError
        text = text.strip
        return [fallback_code, text.empty? ? fallback_message : text[0, 500], nil]
      end
      return [fallback_code, fallback_message, nil] unless body.is_a?(Hash) && body.key?("error")

      error = body["error"]
      # A few edge routes answer {"error": "message"}.
      return [fallback_code, error, nil] if error.is_a?(String)
      return [fallback_code, fallback_message, nil] unless error.is_a?(Hash)

      [
        error["code"].is_a?(String) ? error["code"] : fallback_code,
        error["message"].is_a?(String) ? error["message"] : fallback_message,
        error["details"].is_a?(Hash) ? error["details"] : nil
      ]
    end
    private_class_method :parse_body
  end

  # 400: the request is invalid (`VALIDATION_FAILED`, `CONTENT_TOO_LONG`, ...). `details["issues"]` lists the problems.
  class BadRequestError < APIError; end

  # 401: the API key is missing, wrong or revoked.
  class AuthenticationError < APIError; end

  # 403: the key lacks a scope, the plan lacks a feature, or the account is suspended.
  class PermissionDeniedError < APIError; end

  # 404: no such resource belongs to you.
  class NotFoundError < APIError; end

  # 409: the resource's state does not allow it, or an idempotency key was reused.
  class ConflictError < APIError; end

  # 413: the request body is too large; upload files with `client.media.upload`.
  class PayloadTooLargeError < APIError; end

  # 422: the request is well formed but cannot be done (for example analytics on Discord).
  class UnprocessableEntityError < APIError; end

  # 429: `RATE_LIMITED` or `QUOTA_EXCEEDED`. Retried automatically when `Retry-After` is short.
  class RateLimitError < APIError
    # @return [Float, nil] seconds the API asked to wait (`Retry-After`)
    def retry_after
      Ampost.parse_retry_after(headers["retry-after"])
    end
  end

  # 5xx: something failed on Ampost's side or at a platform.
  class InternalServerError < APIError; end

  # No response: DNS, TCP, TLS or a reset connection.
  class APIConnectionError < Error; end

  # No response within `timeout`.
  class APITimeoutError < APIConnectionError; end

  # `media.upload` did not end with a usable file.
  #
  # `reason`: `upload_rejected` (storage refused the PUT), `failed` or `expired` (the upload's status),
  # or `timeout` (still processing).
  class MediaUploadError < Error
    # @return [String]
    attr_reader :reason
    # @return [String]
    attr_reader :upload_id

    def initialize(message, reason, upload_id)
      super(message)
      @reason = reason
      @upload_id = upload_id
    end
  end

  STATUS_ERRORS = {
    400 => BadRequestError,
    401 => AuthenticationError,
    403 => PermissionDeniedError,
    404 => NotFoundError,
    409 => ConflictError,
    413 => PayloadTooLargeError,
    422 => UnprocessableEntityError,
    429 => RateLimitError
  }.freeze
  private_constant :STATUS_ERRORS

  # @return [Class] the APIError subclass for an HTTP status
  def self.error_class(status)
    return InternalServerError if status >= 500

    STATUS_ERRORS.fetch(status, APIError)
  end

  # `Retry-After` in seconds: delta-seconds or an HTTP date.
  #
  # @param value [String, nil]
  # @return [Float, nil]
  def self.parse_retry_after(value)
    return nil if value.nil? || value.strip.empty?

    value = value.strip
    return [Float(value), 0.0].max if value.match?(/\A\d+(\.\d+)?\z/)

    [Time.httpdate(value) - Time.now, 0.0].max
  rescue ArgumentError
    nil
  end
end
