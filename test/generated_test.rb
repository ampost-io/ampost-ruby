# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "tmpdir"
require "test_helper"

ROOT = File.expand_path("..", __dir__)
SPEC = JSON.parse(File.read(File.join(ROOT, "openapi.json"), encoding: "utf-8"))

def spec_operations
  SPEC["paths"].flat_map do |path, item|
    item.slice("get", "post", "put", "patch", "delete").map { |method, op| [op["operationId"], op.merge("path" => path, "method" => method)] }
  end.to_h
end

class GeneratedTest < AmpostTest
  def test_every_operation_has_a_method
    assert_equal spec_operations.keys.sort, Ampost::OPERATIONS.map { |o| o[:operation_id] }.sort
    c = Ampost::Client.new(api_key: "k")
    Ampost::OPERATIONS.each do |op|
      assert_respond_to c.public_send(op[:resource]), op[:method], op[:operation_id]
    end
  end

  def test_marks_exactly_the_operations_that_take_an_idempotency_key
    expected = spec_operations.select { |_, op| (op["parameters"] || []).any? { |p| p["name"] == "Idempotency-Key" } }.keys
    assert_equal expected.sort, Ampost::OPERATIONS.select { |o| o[:idempotent] }.map { |o| o[:operation_id] }.sort
  end

  def test_version_matches_the_changelog
    assert_match(/^## #{Regexp.escape(Ampost::VERSION)}\b/, File.read(File.join(ROOT, "CHANGELOG.md"), encoding: "utf-8"))
  end

  def test_the_generator_is_idempotent_and_keeps_the_snapshot_format
    out = File.join(ROOT, "lib", "ampost", "generated", "resources.rb")
    snapshot = File.join(ROOT, "openapi.json")
    before = [File.read(out), File.read(snapshot)]
    Dir.mktmpdir do |dir|
      copy = File.join(dir, "openapi.json")
      FileUtils.cp(snapshot, copy)
      # --spec rewrites the snapshot from the copy: byte for byte the same when the format matches.
      assert system(RbConfig.ruby, File.join(ROOT, "scripts", "generate.rb"), "--spec", copy, out: File::NULL)
    end
    assert_equal before, [File.read(out), File.read(snapshot)], "run `ruby scripts/generate.rb` and commit the result"
  end
end

# One test per generated method: it sends the operation's HTTP method, path, query, body and
# Idempotency-Key as the spec says.
class OperationsTest < AmpostTest
  Ampost::OPERATIONS.each do |op|
    define_method("test_#{op[:operation_id]}") do
      spec = spec_operations.fetch(op[:operation_id])
      answer = op[:paginated] ? page([{ "id" => "x" }]) : json_response({ "id" => "x" })
      api = FakeTransport.new(answer)
      resource = client(api).public_send(op[:resource])
      args = []
      kwargs = {}
      path = op[:path].dup
      body = nil
      resource.method(op[:method]).parameters.each do |kind, name|
        case kind
        when :req
          if name == :body
            body = { "probe" => op[:operation_id] }
            args << body
          else
            value = "#{name}/1"
            args << value
            path = path.sub(/\{\w+\}/, "#{name}%2F1")
          end
        when :opt
          body = { "probe" => op[:operation_id] }
          args << body
        when :keyreq then kwargs[name] = "value"
        end
      end
      result = resource.public_send(op[:method], *args, **kwargs)
      request = api.last
      assert_equal spec["method"].upcase, request.method
      assert_equal "https://api.ampost.io#{path}", request.url.split("?").first
      if spec.dig("requestBody", "content", "application/json")
        assert_equal body, JSON.parse(request.body)
      else
        assert_nil request.body
      end
      assert_equal op[:idempotent], request.headers.key?("Idempotency-Key")
      required = (spec["parameters"] || []).select { |p| p["in"] == "query" && p["required"] }.map { |p| [p["name"], "value"] }
      assert_equal required, query_params(request)
      if op[:paginated]
        assert_instance_of Ampost::Page, result
      else
        assert_equal({ "id" => "x" }, result)
      end
    end
  end
end
