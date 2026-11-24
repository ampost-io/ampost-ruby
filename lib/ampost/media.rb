# frozen_string_literal: true

module Ampost
  # `client.media`: the generated `create_upload` and `get_upload`, plus `upload` and `wait_for_upload`.
  class MediaResource < Resources::Media
    MIME_TYPES = {
      "jpg" => "image/jpeg",
      "jpeg" => "image/jpeg",
      "png" => "image/png",
      "webp" => "image/webp",
      "gif" => "image/gif",
      "mp4" => "video/mp4",
      "m4v" => "video/mp4",
      "mov" => "video/quicktime",
      "webm" => "video/webm"
    }.freeze

    # Large videos take a while to send; the API's per-request timeout would be too short.
    UPLOAD_TIMEOUT = 15 * 60

    # The MIME type for a file name's extension, or nil.
    #
    # @param file_name [String]
    # @return [String, nil]
    def self.guess_content_type(file_name)
      extension = File.extname(file_name.to_s).delete_prefix(".").downcase
      extension.empty? ? nil : MIME_TYPES[extension]
    end

    # Uploads one image or video and returns it as a `media` item for `posts.create`:
    #
    #   video = client.media.upload("launch.mp4")
    #   client.posts.create({ text: "We launched", media: [video], targets: [{ platforms: ["youtube"] }] })
    #
    # Steps: `create_upload`, a PUT of the bytes to the returned `uploadUrl` (straight to storage; your
    # API key is not sent there), then `get_upload` until Ampost has checked the file.
    #
    # @param file [String, Pathname, IO] A path, or an IO (File, StringIO) to read the bytes from.
    # @param file_name [String, nil] Default: the path's name, else `file`.
    # @param content_type [String, nil] MIME type, for example `video/mp4`. Default: guessed from the file name.
    # @param poll_interval [Numeric] Seconds between status checks.
    # @param wait_timeout [Numeric] Seconds to wait for processing before raising MediaUploadError (`timeout`).
    # @param options [Hash] `timeout:`, `max_retries:` and `extra_headers:` for the API calls.
    # @return [Hash] `url`, `type`, `mimeType`, `sizeBytes`, `width`, `height`, `durationSeconds`
    # @raise [Ampost::MediaUploadError]
    def upload(file, file_name: nil, content_type: nil, poll_interval: 2, wait_timeout: 120, **options)
      content, name, mime = read(file, file_name, content_type)
      created = create_upload({ "fileName" => name }, **options)
      response = @client.send_raw(
        created.fetch("method"),
        created.fetch("uploadUrl"),
        headers: created.fetch("headers", {}).merge("x-content-type" => mime),
        body: content,
        timeout: options.fetch(:timeout, UPLOAD_TIMEOUT)
      )
      unless response.success?
        raise MediaUploadError.new(
          "Storage refused the file: HTTP #{response.status} #{response.body.to_s[0, 300]}".strip,
          "upload_rejected",
          created.fetch("id")
        )
      end

      first_file(wait_for_upload(created.fetch("id"), poll_interval: poll_interval, wait_timeout: wait_timeout, **options))
    end

    # Polls an upload until it is `completed` and returns it. Raises MediaUploadError when it `failed`
    # or `expired`, or is still pending after `wait_timeout` seconds. Use it after showing
    # `uploadPageUrl` to a user.
    #
    # @return [Hash] the `MediaUpload`
    # @raise [Ampost::MediaUploadError]
    def wait_for_upload(upload_id, poll_interval: 2, wait_timeout: 120, **options)
      deadline = monotonic + wait_timeout
      loop do
        upload = get_upload(upload_id, **options)
        check_status(upload, upload_id)
        return upload if upload["status"] == "completed"

        if monotonic + poll_interval > deadline
          raise MediaUploadError.new("The upload is still being processed; check it later with get_upload",
                                     "timeout", upload_id)
        end

        @client.send(:sleep_for, poll_interval)
      end
    end

    private

    def read(file, file_name, content_type)
      name = nil
      if file.is_a?(String) || file.respond_to?(:to_path)
        path = file.respond_to?(:to_path) ? file.to_path : file
        content = File.binread(path)
        name = File.basename(path)
      elsif file.respond_to?(:read)
        content = file.read.to_s.b
        name = File.basename(file.path) if file.respond_to?(:path) && file.path
      else
        raise ArgumentError, "upload takes a file path or an IO, got #{file.class}"
      end
      name = file_name || name || "file"
      mime = content_type || self.class.guess_content_type(name)
      raise Error, "Cannot tell the MIME type of #{name.inspect}: pass content_type:" unless mime

      [content, name, mime]
    end

    def check_status(upload, upload_id)
      case upload["status"]
      when "failed"
        raise MediaUploadError.new("The upload failed: #{upload["error"] || "the file was refused"}", "failed", upload_id)
      when "expired"
        raise MediaUploadError.new("The upload expired before a file arrived; create a new one", "expired", upload_id)
      end
    end

    def first_file(upload)
      file = (upload["files"] || []).first
      raise MediaUploadError.new("The upload completed without a file", "failed", upload["id"]) unless file

      file.slice("url", "type", "mimeType", "sizeBytes", "width", "height", "durationSeconds")
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
