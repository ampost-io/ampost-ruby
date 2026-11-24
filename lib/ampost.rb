# frozen_string_literal: true

# The official Ruby client for the Ampost API: https://ampost.io/docs?ref=github
#
#   require "ampost"
#
#   client = Ampost::Client.new # reads AMPOST_API_KEY
#   client.posts.create({ text: "Hello", targets: [{ platforms: ["bluesky"] }], publishNow: true })
module Ampost
end

require_relative "ampost/version"
require_relative "ampost/errors"
require_relative "ampost/transport"
require_relative "ampost/page"
require_relative "ampost/resource"
require_relative "ampost/generated/resources"
require_relative "ampost/media"
require_relative "ampost/client"
