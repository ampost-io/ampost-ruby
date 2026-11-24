# frozen_string_literal: true

require "openssl"
require "test_helper"

README = File.read(File.expand_path("../README.md", __dir__), encoding: "utf-8")

# The README names only methods that exist, and its webhook check accepts what Ampost sends.
class ReadmeTest < AmpostTest
  def test_every_client_method_in_the_readme_exists
    c = Ampost::Client.new(api_key: "k")
    calls = README.scan(/client\.(\w+)\.(\w+)/).uniq
    assert_operator calls.size, :>=, 10
    calls.each do |resource, method|
      assert_respond_to c.public_send(resource), method, "client.#{resource}.#{method}"
    end
    %w[list get update delete test list_deliveries redeliver].each { |m| assert_respond_to c.webhooks, m }
  end

  def test_the_webhook_check_accepts_a_signed_delivery_and_nothing_else
    snippet = README[/```ruby\n(require "openssl"\n.*?def verify_ampost_webhook.*?)```/m, 1]
    refute_nil snippet
    receiver = Object.new
    receiver.instance_eval(snippet)
    secret = "whsec_test"
    body = JSON.generate({ type: "post.published", data: { id: "p1" } })
    timestamp = Time.now.to_i.to_s
    # As src/lib/webhooks/signing.ts in the Ampost app signs it.
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")}"
    assert receiver.verify_ampost_webhook(body, timestamp, signature, secret)
    refute receiver.verify_ampost_webhook("#{body} ", timestamp, signature, secret)
    refute receiver.verify_ampost_webhook(body, timestamp, signature, "whsec_other")
    refute receiver.verify_ampost_webhook(body, timestamp, "sha256=short", secret)
    refute receiver.verify_ampost_webhook(body, timestamp, nil, secret)
    refute receiver.verify_ampost_webhook(body, nil, signature, secret)
    old = (Time.now.to_i - 301).to_s
    refute receiver.verify_ampost_webhook(body, old, "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, "#{old}.#{body}")}", secret)
  end
end
