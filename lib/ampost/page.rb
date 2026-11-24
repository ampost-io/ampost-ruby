# frozen_string_literal: true

module Ampost
  # One page of a list. `page.data` is this page; `each` (and every Enumerable method) walks every
  # item across pages, fetching the next pages as it goes:
  #
  #   page = client.posts.list(status: "failed", limit: 50)
  #   page.data           # this page's posts
  #   page.each { |post| client.posts.retry(post["id"]) } # every failed post
  #   client.accounts.list.first(5)                        # stops fetching after 5 items
  class Page
    include Enumerable

    # @return [Hash] the raw response: `{"data" => [...], "pagination" => {...}}`
    attr_reader :response
    # @return [Array<Hash>] this page's items
    attr_reader :data
    # @return [Hash] `limit`, `offset`, `total` and `hasMore` as the API sends them
    attr_reader :pagination

    # @param response [Hash] a list response
    # @param fetch [#call] takes an offset, returns the list response there
    def initialize(response, fetch)
      @response = response
      @data = response.fetch("data")
      @pagination = response.fetch("pagination")
      @fetch = fetch
    end

    # @return [Integer] items across all pages
    def total
      Integer(@pagination.fetch("total"))
    end

    # Items on this page (`count` walks every page).
    #
    # @return [Integer]
    def size
      @data.size
    end
    alias length size

    def next_page?
      @pagination["hasMore"] == true && !@data.empty?
    end

    # @return [Page]
    # @raise [Ampost::Error] on the last page
    def next_page
      raise Error, "No next page" unless next_page?

      Page.new(@fetch.call(Integer(@pagination.fetch("offset")) + @data.size), @fetch)
    end

    # Yields this page and each next page.
    #
    # @return [Enumerator] without a block
    def each_page
      return enum_for(:each_page) unless block_given?

      page = self
      loop do
        yield page
        break unless page.next_page?

        page = page.next_page
      end
      self
    end

    # Yields every item, page after page.
    #
    # @return [Enumerator] without a block
    def each(&block)
      return enum_for(:each) unless block

      each_page { |page| page.data.each(&block) }
      self
    end

    def inspect
      "#<#{self.class.name} data=<#{@data.size} items> pagination=#{@pagination.inspect}>"
    end
  end
end
