# Ampost Ruby SDK

The official Ruby client for the [Ampost API](https://ampost.io/docs?ref=github): publish, schedule
and track posts on Instagram, Facebook, Threads, X, YouTube, Pinterest, Bluesky, Telegram and Discord
with one call.

- Every endpoint, generated from the [OpenAPI document](https://api.ampost.io/openapi.json), with YARD docs
- Retries on 429 and 5xx with `Retry-After`, automatic `Idempotency-Key`s, typed errors
- Pagination with `each` and a one-call media upload
- Ruby 3.1+, no runtime dependencies (`net/http` and `json` from the standard library)

## Install

```sh
gem install ampost
```

Or in your `Gemfile`:

```ruby
gem "ampost"
```

## Quick start

Create an API key in [Settings, API keys](https://ampost.io/app/settings/api-keys?ref=github), connect
Bluesky and Threads in the [dashboard](https://ampost.io/app?ref=github), then:

```ruby
require "ampost"

client = Ampost::Client.new(api_key: ENV.fetch("AMPOST_API_KEY"))

post = client.posts.create({
  text: "Hello from the Ampost API 👋",
  targets: [{ platforms: ["bluesky", "threads"] }],
  publishNow: true
})
puts post["id"], post["status"]
post["platformPosts"].each { |p| puts "#{p["platform"]}: #{p["status"]}" }
```

Request bodies are Hashes with the API's field names (`publishNow`, `scheduledFor`), with symbol or
string keys; pass them in braces, as above. Responses are Hashes with string keys, exactly as the
[API docs](https://ampost.io/docs?ref=github) show them.

Leave out `publishNow` for a draft, or schedule the post (paid plans):

```ruby
client.posts.create({
  text: "See you at the launch",
  targets: [{ platforms: ["bluesky"] }],
  scheduledFor: Time.utc(2026, 12, 1, 9) # or "2026-12-01T09:00:00Z"
})
```

Check a post against every platform's rules and your accounts without creating it:

```ruby
result = client.posts.validate({ text: "x" * 400, targets: [{ platforms: ["bluesky"] }] })
result["valid"] # => false, with the reasons in result["errors"] and result["targets"]
```

List your connected accounts:

```ruby
client.accounts.list.each do |account|
  puts "#{account["platform"]} #{account["status"]}"
end
```

## Authentication

Every request sends the key as `Authorization: Bearer <key>`. Without `api_key:` the client reads
`AMPOST_API_KEY`, and `AMPOST_BASE_URL` overrides `https://api.ampost.io`.

```ruby
client = Ampost::Client.new(
  api_key: "amp_...",
  base_url: "https://api.ampost.io",
  max_retries: 2,  # after a 429, a 5xx or a network error
  timeout: 60      # seconds per attempt
)
```

A key has scopes (`posts:write`, `analytics:read`, ...) and can be limited to some platform sets. A
call outside them raises `Ampost::PermissionDeniedError` with `code` `INSUFFICIENT_SCOPE` or
`PLATFORM_SET_NOT_ALLOWED`. See [scopes](https://ampost.io/docs?ref=github#scopes).

The client holds no connection (each request opens its own), so one client can be shared between
threads. Proxies come from `https_proxy` as usual for `Net::HTTP`.

## Media upload

`media.upload` takes a path, a `Pathname` or an IO (`File`, `StringIO`), sends the file straight to
storage (your API key is not sent there), waits until Ampost has checked it and returns a `media` item:

```ruby
video = client.media.upload("launch.mp4")
client.posts.create({
  text: "We launched 🚀",
  media: [video],
  targets: [{ platforms: ["youtube", "threads"] }],
  options: { youtube: { title: "Launch day" } }
})
```

The MIME type comes from the file name; pass `content_type:` (and `file_name:` for an IO) otherwise.
Public URLs work without an upload: `media: [{ url: "https://example.com/a.jpg", type: "image" }]`.
For files on a user's device, show `uploadPageUrl` from `client.media.create_upload` and call
`client.media.wait_for_upload(upload_id)`. A refused or expired upload raises `Ampost::MediaUploadError`
with a `reason`. See [media upload](https://ampost.io/docs?ref=github#media-upload).

## Errors

Every API error is `{"error": {"code", "message", "details"}}`, raised as a subclass of `Ampost::APIError`:

```ruby
begin
  client.posts.create({ text: "x" * 500, targets: [{ platforms: ["bluesky"] }] })
rescue Ampost::BadRequestError => e
  puts e.code, e.details   # CONTENT_TOO_LONG, ...
rescue Ampost::RateLimitError => e
  puts "retry in #{e.retry_after} s"
rescue Ampost::APIError => e
  puts e.status, e.code, e.api_message, e.request_id
end
```

| Status | Class | Typical `code` |
| ------ | ----- | -------------- |
| 400 | `BadRequestError` | `VALIDATION_FAILED`, `CONTENT_TOO_LONG`, `PLATFORM_NOT_CONNECTED` |
| 401 | `AuthenticationError` | `UNAUTHORIZED` |
| 403 | `PermissionDeniedError` | `INSUFFICIENT_SCOPE`, `UPGRADE_REQUIRED`, `PLATFORM_COMING_SOON` |
| 404 | `NotFoundError` | `POST_NOT_FOUND`, `ACCOUNT_NOT_FOUND` |
| 409 | `ConflictError` | `INVALID_STATUS_TRANSITION`, `IDEMPOTENCY_KEY_REUSED` |
| 413 | `PayloadTooLargeError` | `PAYLOAD_TOO_LARGE` |
| 422 | `UnprocessableEntityError` | `ANALYTICS_NOT_AVAILABLE_ON_PLATFORM` |
| 429 | `RateLimitError` | `RATE_LIMITED`, `QUOTA_EXCEEDED` |
| 5xx | `InternalServerError` | `INTERNAL_ERROR`, `PLATFORM_REQUEST_FAILED` |

`e.message` is `"<status> <code>: <message>"`; `e.api_message` is the API's message alone. No
response at all is `Ampost::APIConnectionError` (`Ampost::APITimeoutError` after `timeout`). All of
them extend `Ampost::Error`. Quote `e.request_id` when you contact support. Every code is listed in
[the docs](https://ampost.io/docs?ref=github#errors).

A post that was accepted can still fail on one platform: check `post["platformPosts"][i]["status"]` and
`["error"]`, or subscribe to webhooks (below).

## Idempotency

`posts.create`, `posts.publish`, `posts.retry`, `posts.import_csv`, `accounts.connect`,
`platform_sets.create`, `webhooks.create` and `feedback.submit` take an `Idempotency-Key`. The SDK
sends a new key with each call and keeps it across that call's retries, so a retried request never
posts twice. To stay safe across restarts too (a cron job, a Sidekiq worker), pass your own key:

```ruby
client.posts.create(
  { text: "v1.4.0 is out", targets: [{ platforms: ["bluesky"] }], publishNow: true },
  idempotency_key: "release-v1.4.0"
)
```

The same key with the same request returns the first result for 24 hours; with a different request
it is `Ampost::ConflictError` `IDEMPOTENCY_KEY_REUSED`. See
[idempotency](https://ampost.io/docs?ref=github#idempotency).

## Retries

| What happened | Retried? |
| ------------- | -------- |
| 429 `RATE_LIMITED`, `QUOTA_EXCEEDED` | Yes, after `Retry-After`, if it is under `max_retry_delay` (60 s) |
| 409 `IDEMPOTENCY_REQUEST_IN_PROGRESS` | Yes |
| 5xx, timeout, network error | Reads and calls with an `Idempotency-Key` only |
| Anything else | No |

Waits without `Retry-After` back off from 0.5 s to 8 s. Set `max_retries:` on the client or per call:
`client.posts.get(post_id, max_retries: 0)`. Every method also takes `timeout:` and `extra_headers:`.

## Pagination

List methods return an `Ampost::Page`: `data` is the first page, and `each` (with every `Enumerable`
method) walks every item, fetching the next pages as it goes:

```ruby
page = client.posts.list(status: "failed", limit: 50)
page.data         # this page
page.total        # items across all pages
page.next_page?   # => true / false

client.posts.list(status: "failed").each do |post|
  client.posts.retry(post["id"])
end

client.accounts.list.first(5)          # fetches only the pages it needs
client.posts.list.each_page { |p| puts p.size }
```

Query parameters are keyword arguments in snake_case: `platform_set_id:` for `platformSetId`.

## Webhooks

Subscribe a URL to events instead of polling:

```ruby
webhook = client.webhooks.create({
  url: "https://example.com/ampost/webhooks",
  events: ["post.published", "post.failed", "account.needs_reconnect"]
})
secret = webhook["secret"] # shown only in this response: store it
```

`client.webhooks.list`, `get`, `update`, `delete`, `test`, `list_deliveries` and `redeliver` manage
them. Ampost signs each delivery: `Ampost-Signature` is `sha256=` plus the hex HMAC-SHA256 of
`<Ampost-Timestamp>.<raw body>` with the webhook's secret. Check it on the raw body, before parsing:

```ruby
require "openssl"

# raw_body: the request body as received (request.raw_post in Rails), before JSON.parse.
def verify_ampost_webhook(raw_body, timestamp, signature, secret)
  return false unless timestamp.to_s.match?(/\A\d+\z/) && signature
  # Reject old requests so a captured one cannot be replayed.
  return false if (Time.now.to_i - timestamp.to_i).abs > 300

  expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{raw_body}")}"
  expected.bytesize == signature.bytesize && OpenSSL.fixed_length_secure_compare(expected, signature)
end

# In a Rails controller:
# verify_ampost_webhook(request.raw_post, request.headers["Ampost-Timestamp"],
#                       request.headers["Ampost-Signature"], ENV["AMPOST_WEBHOOK_SECRET"])
```

Events and their `data` are in [webhooks](https://ampost.io/docs?ref=github#webhooks).

## Everything else

Each tag of the API is a reader on the client: `posts`, `accounts`, `platform_sets` (and posting
queues), `media`, `analytics`, `webhooks`, `platforms`, `docs`, `feedback`, with one method per
operation. Every method's YARD docs list its parameters and body fields, from the OpenAPI document.
`Ampost::OPERATIONS` lists them all with their HTTP method and path.

`client.platforms.list` returns each platform's limits and options. AI agents can use the same API
through the hosted MCP server at `https://api.ampost.io/mcp` ([setup](https://ampost.io/docs/mcp?ref=github)).

To send requests through your own HTTP code (instrumentation, another HTTP library), pass
`transport:`, an object whose `call(request)` takes an `Ampost::Transport::Request` and returns an
`Ampost::Transport::Response`; see `lib/ampost/transport.rb`.

## Development

`lib/ampost/generated/` comes from `openapi.json`; never edit it by hand.

```sh
bundle install
ruby scripts/generate.rb                                              # from the committed openapi.json
ruby scripts/generate.rb --spec https://api.ampost.io/openapi.json    # refresh the snapshot, then generate
bundle exec rake test
AMPOST_API_KEY=amp_... bundle exec ruby -Ilib -Itest test/smoke_test.rb   # reads and validates only
gem build ampost.gemspec
```

Why this generator: OpenAPI Generator's Ruby client emits a model class and a file per schema and
depends on Typhoeus; the result is large and reads unlike the API docs. `scripts/generate.rb` uses
only the standard library and writes one method per operation with its docs, so requests and
responses stay the plain JSON the docs show. The hand-written client (`lib/ampost/client.rb`) adds
auth, retries, idempotency, errors and pagination on `Net::HTTP`.

## Links

- [API docs](https://ampost.io/docs?ref=github) and [llms.txt](https://ampost.io/llms.txt?ref=github)
- [MCP server](https://ampost.io/docs/mcp?ref=github)
- [Pricing](https://ampost.io/pricing?ref=github)
- [Node.js SDK](https://github.com/ampost-io/ampost-node), [Python SDK](https://github.com/ampost-io/ampost-python), [CLI](https://github.com/ampost-io/ampost-cli)

## License

MIT
