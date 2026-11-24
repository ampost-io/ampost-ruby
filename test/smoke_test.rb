# frozen_string_literal: true

require "test_helper"

# Against the real API, only when AMPOST_API_KEY is set. Reads and validates; creates nothing.
class SmokeTest < AmpostTest
  def setup
    super
    skip "AMPOST_API_KEY is not set" unless SMOKE_API_KEY
  end

  def live
    Ampost::Client.new(api_key: SMOKE_API_KEY, base_url: SMOKE_BASE_URL)
  end

  def test_lists_platforms_with_their_rules
    platforms = live.platforms.list
    assert_includes platforms.map { |p| p["platform"] }, "bluesky"
    assert(platforms.data.all? { |p| p.key?("text") })
  end

  def test_reads_one_page_of_posts_and_accounts
    c = live
    assert_equal 1, c.posts.list(limit: 1).pagination["limit"]
    assert_kind_of Array, c.accounts.list(limit: 5).data
  end

  def test_validates_a_post_without_creating_it
    result = live.posts.validate({ text: "Hello from the ampost-ruby smoke test", targets: [{ platforms: ["bluesky"] }] })
    assert_includes [true, false], result["valid"]
  end

  def test_answers_a_wrong_key_with_authentication_error
    c = Ampost::Client.new(api_key: "amp_wrong_key_for_smoke_test", base_url: SMOKE_BASE_URL, max_retries: 0)
    assert_raises(Ampost::AuthenticationError) { c.posts.list(limit: 1) }
  end
end
