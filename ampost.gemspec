# frozen_string_literal: true

require_relative "lib/ampost/version"

Gem::Specification.new do |spec|
  spec.name = "ampost"
  spec.version = Ampost::VERSION
  spec.authors = ["Ampost"]
  spec.email = ["support@ampost.io"]
  spec.summary = "Official Ruby client for the Ampost API: publish and schedule posts on Instagram, " \
                 "Facebook, Threads, X, YouTube, Pinterest, Bluesky, Telegram and Discord"
  spec.description = "Publish, schedule and track social media posts with one API call. Every endpoint of the " \
                     "Ampost REST API, generated from its OpenAPI document, with retries, idempotency keys, " \
                     "typed errors, pagination and media upload. No runtime dependencies."
  spec.homepage = "https://ampost.io?ref=rubygems"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "documentation_uri" => "https://ampost.io/docs?ref=rubygems",
    "source_code_uri" => "https://github.com/ampost-io/ampost-ruby",
    "changelog_uri" => "https://github.com/ampost-io/ampost-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/ampost-io/ampost-ruby/issues"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]
end
