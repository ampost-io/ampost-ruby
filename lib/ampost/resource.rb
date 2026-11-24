# frozen_string_literal: true

require "uri"

module Ampost
  # Base of the generated resource classes in lib/ampost/generated/resources.rb.
  class Resource
    # @param client [Ampost::Client]
    def initialize(client)
      @client = client
    end

    def inspect
      "#<#{self.class.name}>"
    end

    private

    # Encodes one path parameter.
    def path(value)
      unless value.is_a?(String) && !value.empty?
        raise ArgumentError, "Expected a non-empty String path parameter, got #{value.inspect}"
      end

      URI.encode_www_form_component(value).gsub("+", "%20")
    end
  end
end
