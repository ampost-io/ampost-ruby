# frozen_string_literal: true

require "test_helper"

class PageTest < AmpostTest
  def offsets(api)
    api.requests.map { |r| query_params(r).to_h["offset"] }
  end

  def test_returns_the_first_page
    api = FakeTransport.new(page([{ "id" => "a" }, { "id" => "b" }], 0, 5))
    first = client(api).posts.list(limit: 2)
    assert_instance_of Ampost::Page, first
    assert_equal [{ "id" => "a" }, { "id" => "b" }], first.data
    assert_equal 5, first.total
    assert first.next_page?
    assert_equal 2, first.size
    assert_equal [nil], offsets(api)
  end

  def test_each_walks_every_item_moving_the_offset_by_the_page_size
    api = FakeTransport.new(page([1, 2], 0, 5), page([3, 4], 2, 5), page([5], 4, 5))
    assert_equal [1, 2, 3, 4, 5], client(api).posts.list(status: "failed").to_a
    assert_equal [nil, "2", "4"], offsets(api)
    assert(api.requests.all? { |r| query_params(r).to_h["status"] == "failed" })
  end

  def test_starts_from_the_callers_offset
    api = FakeTransport.new(page([3, 4], 10, 14), page([5], 12, 13))
    assert_equal [3, 4, 5], client(api).accounts.list(offset: 10).to_a
    assert_equal %w[10 12], offsets(api)
  end

  def test_fetches_lazily
    api = FakeTransport.new(page([1, 2], 0, 6), page([3, 4], 2, 6))
    assert_equal [1, 2, 3], client(api).posts.list.first(3)
    assert_equal 2, api.requests.size
  end

  def test_stops_on_an_empty_page_even_if_has_more
    api = FakeTransport.new(page([], 0, 10, true))
    assert_equal [], client(api).posts.list.to_a
  end

  def test_each_page_and_next_page
    api = FakeTransport.new(page([1, 2], 0, 3), page([3], 2, 3))
    pages = client(api).posts.list.each_page.to_a
    assert_equal [[1, 2], [3]], pages.map(&:data)
    assert_raises(Ampost::Error) { pages.last.next_page }
  end

  def test_each_without_a_block_is_an_enumerator
    api = FakeTransport.new(page([1], 0, 2), page([2], 1, 2))
    assert_equal [2, 4], client(api).platform_sets.list.each.map { |n| n * 2 }
  end

  def test_inspect_is_short
    api = FakeTransport.new(page([1, 2], 0, 2))
    assert_match(/data=<2 items>/, client(api).posts.list.inspect)
  end
end
