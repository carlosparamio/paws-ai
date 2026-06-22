# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "securerandom"
require "tempfile"
require "time"
require "uri"
require "zlib"
require_relative "graphics_presenter"

module PAWS
  module Web
    # Asynchronously turns the deterministic PAWS render for a picture into an
    # optional richer image. The classic render is always returned immediately;
    # generated assets are cached and announced through a small polling endpoint.
    class AIGraphicsEnhancer
      DEFAULT_STYLE = "pixelart"
      STYLES = %w[pixelart cartoon realistic painting].freeze
      PROVIDERS = %w[openai openrouter].freeze
      WIDTH = GraphicsPresenter::WIDTH
      PROMPT_ROOT = File.expand_path("../prompts/ai_graphics", __dir__)
      SPECTRUM_PALETTE = [
        [0, 0, 0],
        [0, 0, 215],
        [215, 0, 0],
        [215, 0, 215],
        [0, 215, 0],
        [0, 215, 215],
        [215, 215, 0],
        [215, 215, 215],
      ].freeze
      SPECTRUM_BRIGHT_PALETTE = [
        [0, 0, 0],
        [0, 0, 255],
        [255, 0, 0],
        [255, 0, 255],
        [0, 255, 0],
        [0, 255, 255],
        [255, 255, 0],
        [255, 255, 255],
      ].freeze

      def initialize(game_slug:, cache_root:, style: DEFAULT_STYLE, model: nil, api_key: nil, endpoint: nil, provider: nil, http_client: nil, logger: nil, cache_only: false, image_size: nil)
        @game_slug = self.class.safe_slug(game_slug)
        @cache_root = cache_root
        @style = STYLES.include?(style.to_s) ? style.to_s : DEFAULT_STYLE
        @cache_only = cache_only
        if @cache_only
          @api_key = api_key
          @endpoint = endpoint
          @provider = provider.to_s.strip.empty? ? nil : normalize_provider(provider, endpoint)
          @model = model.to_s.strip.empty? ? nil : model.to_s
          @max_tokens = nil
          @image_size = nil
        else
          @api_key = required_value(api_key || ENV["AI_GRAPHICS_API_KEY"], "AI_GRAPHICS_API_KEY")
          configured_endpoint = endpoint || ENV["AI_GRAPHICS_ENDPOINT"]
          @provider = normalize_provider(provider || ENV["AI_GRAPHICS_PROVIDER"], configured_endpoint)
          @model = required_value(model || ENV["AI_GRAPHICS_MODEL"], "AI_GRAPHICS_MODEL")
          @endpoint = required_value(configured_endpoint, "AI_GRAPHICS_ENDPOINT")
          @max_tokens = configured_max_tokens
          @image_size = optional_value(image_size || ENV["AI_GRAPHICS_IMAGE_SIZE"])
        end
        @http_client = http_client
        @logger = logger || ->(_message) {}
        @jobs = {}
        @mutex = Mutex.new
      end

      attr_reader :game_slug, :style, :model, :provider

      def decorate_frame(frame, description:)
        picture_id = frame.fetch("picture_id").to_i
        if cached?(picture_id)
          log("cache hit #{debug_id(picture_id)} -> #{cached_path(picture_id)}")
          return frame.merge("ai_graphics" => ready_payload(picture_id))
        end

        if @cache_only
          log("cache miss #{debug_id(picture_id)}; cache-only mode leaves PAWS render active")
          return frame
        end

        enqueue(picture_id, frame, description: description)
        frame.merge("ai_graphics" => pending_payload(picture_id))
      end

      def status_for(picture_id)
        picture_id = picture_id.to_i
        return ready_payload(picture_id) if cached?(picture_id)
        return missing_payload(picture_id) if @cache_only

        job = @mutex.synchronize { @jobs[picture_id] }
        return error_payload(picture_id, job.fetch(:error), job: job) if job&.fetch(:state, nil) == :error
        return pending_payload(picture_id, job: job) if job

        pending_payload(picture_id)
      end

      def cached_path(picture_id, style: nil)
        paths = style ? cached_paths_for_style(picture_id, style.to_s) : cached_paths(picture_id)
        paths.find { |path| File.file?(path) } || cache_path_for(picture_id, "jpg", style: style || @style)
      end

      def matches_public_style?(style)
        @style == style.to_s
      end

      def generate_frame(frame, description:, force: false)
        picture_id = frame.fetch("picture_id").to_i
        FileUtils.rm_f(cached_paths(picture_id)) if force
        return ready_payload(picture_id).merge("skipped" => true) if cached?(picture_id)

        generate_and_cache(picture_id, frame, description: description)
        ready_payload(picture_id).merge("skipped" => false)
      end

      def self.safe_slug(value)
        File.basename(value.to_s, ".*").downcase.gsub(/[^a-z0-9._-]+/, "-").gsub(/\A-+|-+\z/, "").then do |slug|
          slug.empty? ? "game" : slug
        end
      end

      private

      def cached?(picture_id)
        cached_paths(picture_id).any? { |path| File.file?(path) }
      end

      def cache_dir
        File.join(@cache_root, @game_slug, @style)
      end

      def public_url(picture_id)
        path = cached_path(picture_id)
        style = cached_style_for_path(path) || @style
        extension = File.extname(path).delete_prefix(".")
        "/cache/#{@game_slug}/#{style}/pic#{picture_id.to_i}.#{extension}?mtime=#{File.mtime(path).to_i}"
      end

      def status_url(picture_id)
        style = cached_style_for_path(cached_path(picture_id)) || @style
        "/api/ai-graphics/#{@game_slug}/#{style}/pic#{picture_id.to_i}/status"
      end

      def ready_payload(picture_id)
        resolved_style = cached_style_for_path(cached_path(picture_id)) || @style
        {
          "state" => "ready",
          "style" => resolved_style,
          "provider" => @provider,
          "model" => @model,
          "cache_path" => cached_path(picture_id),
          "url" => public_url(picture_id),
          "status_url" => status_url(picture_id),
        }.compact
      end

      def pending_payload(picture_id, job: nil)
        {
          "state" => "pending",
          "style" => @style,
          "provider" => @provider,
          "model" => @model,
          "queued_at" => job&.fetch(:queued_at, nil),
          "status_url" => status_url(picture_id),
        }.compact
      end

      def missing_payload(picture_id)
        {
          "state" => "missing",
          "style" => @style,
          "status_url" => status_url(picture_id),
        }
      end

      def error_payload(picture_id, message, job: nil)
        {
          "state" => "error",
          "style" => @style,
          "provider" => @provider,
          "model" => @model,
          "status_url" => status_url(picture_id),
          "message" => message.to_s,
          "failed_at" => job&.fetch(:failed_at, nil),
        }.compact
      end

      def enqueue(picture_id, frame, description:)
        should_spawn = @mutex.synchronize do
          job = @jobs[picture_id]
          next false if job && job.fetch(:state) == :pending

          @jobs[picture_id] = { state: :pending, queued_at: Time.now.utc.iso8601 }
          true
        end
        log("job already pending #{debug_id(picture_id)}") unless should_spawn
        return unless should_spawn

        log("queue #{debug_id(picture_id)} provider=#{@provider} endpoint=#{@endpoint} model=#{@model} cache=#{cached_path(picture_id)}")
        Thread.new do
          Thread.current.abort_on_exception = false
          generate_and_cache(picture_id, frame, description: description)
        rescue StandardError => e
          @mutex.synchronize { @jobs[picture_id] = { state: :error, error: e.message, failed_at: Time.now.utc.iso8601 } }
          log("error #{debug_id(picture_id)} #{e.class}: #{e.message}")
        end
      end

      def generate_and_cache(picture_id, frame, description:)
        log("start #{debug_id(picture_id)}")
        source_png = FramePngEncoder.new(frame, min_dimension: 256).to_png
        source_dimensions = png_dimensions(source_png)
        log("reference #{debug_id(picture_id)} dimensions=#{format_dimensions(source_dimensions)}")
        response = image_client.edit(
          model: @model,
          prompt: prompt_for(description, frame: frame),
          source_png: source_png,
        )
        image_bytes = Base64.decode64(response.fetch("b64_json"))
        extension = image_extension(image_bytes)
        received_dimensions = image_dimensions_for_log(image_bytes, extension)
        log(
          "received #{debug_id(picture_id)} format=#{extension} " \
          "dimensions=#{format_dimensions(received_dimensions)} " \
          "target=#{frame.fetch("logical_width").to_i}x#{frame.fetch("visible_height").to_i}",
        )
        image_bytes = normalize_image_aspect(image_bytes, extension, frame)
        normalized_dimensions = image_dimensions_for_log(image_bytes, extension)
        if normalized_dimensions && normalized_dimensions != received_dimensions
          log("normalized #{debug_id(picture_id)} dimensions=#{format_dimensions(normalized_dimensions)}")
        end
        final_path = cache_path_for(picture_id, extension)

        FileUtils.mkdir_p(cache_dir)
        tmp_path = File.join(cache_dir, ".pic#{picture_id.to_i}.#{SecureRandom.hex(4)}.tmp")
        File.binwrite(tmp_path, image_bytes)
        FileUtils.rm_f(cached_paths(picture_id))
        File.rename(tmp_path, final_path)
        @mutex.synchronize { @jobs[picture_id] = { state: :ready, completed_at: Time.now.utc.iso8601 } }
        log("ready #{debug_id(picture_id)} bytes=#{image_bytes.bytesize} cache=#{final_path}")
      end

      def debug_id(picture_id)
        "#{@game_slug}/#{@style}/pic#{picture_id.to_i}"
      end

      def log(message)
        @logger.call("[ai-graphics] #{message}")
      end

      def image_client
        @image_client ||= image_client_class.new(
          api_key: @api_key,
          endpoint: @endpoint,
          max_tokens: @max_tokens,
          image_size: @image_size,
          http_client: @http_client,
        )
      end

      def image_client_class
        @provider == "openrouter" ? OpenRouterImageClient : OpenAIImageEditClient
      end

      def normalize_provider(value, endpoint)
        explicit = value.to_s.downcase.strip
        return explicit if PROVIDERS.include?(explicit)

        raise ArgumentError, "AI_GRAPHICS_PROVIDER must be one of: #{PROVIDERS.join(", ")}"
      end

      def configured_max_tokens
        return nil unless @provider == "openrouter"

        value = required_value(ENV["AI_GRAPHICS_MAX_TOKENS"], "AI_GRAPHICS_MAX_TOKENS").to_i
        raise ArgumentError, "AI_GRAPHICS_MAX_TOKENS must be a positive integer" unless value.positive?

        value
      end

      def required_value(value, name)
        text = value.to_s.strip
        raise ArgumentError, "#{name} is required when AI graphics are enabled" if text.empty?

        text
      end

      def optional_value(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def prompt_for(description, frame:)
        render_prompt_template("location", {
          style_prompt: load_prompt_template("styles/#{@style}"),
          logical_width: frame.fetch("logical_width"),
          visible_height: frame.fetch("visible_height"),
          aspect_ratio: aspect_ratio(frame.fetch("logical_width").to_i, frame.fetch("visible_height").to_i),
          description: description.to_s.strip.empty? ? "unknown location" : description,
        })
      end

      def render_prompt_template(name, variables)
        template = load_prompt_template(name)
        variables.each do |key, value|
          template = template.gsub("{{#{key}}}", value.to_s)
        end
        template
      end

      def load_prompt_template(name)
        path = File.join(PROMPT_ROOT, "#{name}.md")
        raise ArgumentError, "Missing AI graphics prompt template: #{path}" unless File.file?(path)

        File.read(path).strip
      end

      def cached_paths(picture_id)
        cached_paths_for_style(picture_id, @style)
      end

      def cached_paths_for_style(picture_id, style)
        %w[jpg jpeg png webp].map { |extension| cache_path_for(picture_id, extension, style: style) }
      end

      def cache_path_for(picture_id, extension, style: @style)
        File.join(@cache_root, @game_slug, style, "pic#{picture_id.to_i}.#{extension}")
      end

      def cached_style_for_path(path)
        style = File.basename(File.dirname(path.to_s))
        STYLES.include?(style) ? style : nil
      end

      def image_extension(bytes)
        return "png" if bytes.start_with?("\x89PNG\r\n\x1A\n".b)
        return "jpg" if bytes.start_with?("\xFF\xD8\xFF".b)
        return "webp" if bytes.bytesize >= 12 && bytes.byteslice(0, 4) == "RIFF" && bytes.byteslice(8, 4) == "WEBP"

        "jpg"
      end

      def image_dimensions_for_log(bytes, extension)
        return nil unless command_available?("identify")

        Tempfile.create(["ai-graphics-dimensions", ".#{extension}"]) do |file|
          File.binwrite(file.path, bytes)
          stdout, _stderr, status = Open3.capture3("identify", "-format", "%w %h", file.path)
          return nil unless status.success?

          dimensions = stdout.split.map(&:to_i)
          return nil unless dimensions.size == 2 && dimensions.all?(&:positive?)

          dimensions
        end
      rescue StandardError
        nil
      end

      def format_dimensions(dimensions)
        return "unknown" unless dimensions

        "#{dimensions[0]}x#{dimensions[1]}"
      end

      def png_dimensions(bytes)
        return nil unless bytes.start_with?("\x89PNG\r\n\x1A\n".b) && bytes.bytesize >= 24

        bytes.byteslice(16, 8).unpack("NN")
      end

      def normalize_image_aspect(bytes, extension, frame)
        ImageAspectNormalizer.new(
          bytes,
          extension: extension,
          target_width: frame.fetch("logical_width").to_i,
          target_height: frame.fetch("visible_height").to_i,
          background: dominant_paper_background(frame),
        ).call
      end

      def aspect_ratio(width, height)
        divisor = width.gcd(height)
        "#{width / divisor}:#{height / divisor}"
      end

      def dominant_paper_background(frame)
        attributes = frame.fetch("attributes", [])
        visible_rows = ((frame.fetch("visible_height").to_i + 7) / 8).clamp(1, attributes.size)
        counts = Hash.new(0)
        attributes.first(visible_rows).each do |row|
          row.each do |attribute|
            paper = attribute.fetch("paper", 0).to_i & 7
            bright = !!attribute["bright"]
            counts[[paper, bright]] += 1
          end
        end
        paper, bright = counts.max_by { |_key, count| count }&.first || [0, false]
        palette = bright ? SPECTRUM_BRIGHT_PALETTE : SPECTRUM_PALETTE
        "#%02x%02x%02x" % palette[paper]
      end

      def command_available?(command)
        _stdout, _stderr, status = Open3.capture3("which", command)
        status.success?
      end
    end

    class OpenAIImageEditClient
      def initialize(api_key:, endpoint:, max_tokens: nil, image_size: nil, http_client: nil)
        @api_key = api_key
        @endpoint = URI(endpoint)
        @image_size = image_size
        @http_client = http_client
      end

      def edit(model:, prompt:, source_png:)
        width, height = png_dimensions(source_png)
        payload = {
          model: model,
          prompt: prompt,
          images: [{ image_url: "data:image/png;base64,#{Base64.strict_encode64(source_png)}" }],
          n: 1,
          output_format: "jpeg",
          size: @image_size || image_size(width, height),
        }
        response = post_json(payload)
        image = response.fetch("data").first
        raise "OpenAI image response did not include b64_json" unless image && image["b64_json"]

        image
      end

      private

      def png_dimensions(bytes)
        return [1, 1] unless bytes.start_with?("\x89PNG\r\n\x1A\n".b) && bytes.bytesize >= 24

        bytes.byteslice(16, 8).unpack("NN")
      end

      def image_size(width, height)
        return "1024x1024" if width == height

        width > height ? "1536x1024" : "1024x1536"
      end

      def post_json(payload)
        if @http_client
          return @http_client.call(@endpoint, payload, @api_key)
        end

        request = Net::HTTP::Post.new(@endpoint)
        request["Authorization"] = "Bearer #{@api_key}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)

        response = Net::HTTP.start(@endpoint.host, @endpoint.port, use_ssl: @endpoint.scheme == "https") do |http|
          http.request(request)
        end

        body = response.body.to_s
        raise "OpenAI image request failed (#{response.code}): #{body[0, 500]}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(body)
      end
    end

    class OpenRouterImageClient
      def initialize(api_key:, endpoint:, max_tokens: nil, image_size: nil, http_client: nil)
        @api_key = api_key
        @endpoint = chat_completions_uri(endpoint)
        @max_tokens = max_tokens
        @image_size = image_size
        @http_client = http_client
      end

      def edit(model:, prompt:, source_png:)
        width, height = png_dimensions(source_png)
        payload = {
          model: model,
          messages: [
            {
              role: "user",
              content: [
                { type: "text", text: prompt },
                { type: "image_url", image_url: { url: "data:image/png;base64,#{Base64.strict_encode64(source_png)}" } },
              ],
            },
          ],
          modalities: %w[image],
          image_config: {
            output_format: "jpeg",
            aspect_ratio: supported_aspect_ratio(width, height),
          },
          stream: false,
        }.tap do |body|
          body[:max_tokens] = @max_tokens if @max_tokens
          body[:image_config][:image_size] = @image_size if @image_size
        end
        response = post_json(payload)
        image_url = extract_image_url(response)
        raise "OpenRouter image response did not include an image URL" if image_url.to_s.empty?

        { "b64_json" => decode_image_url(image_url) }
      end

      private

      def chat_completions_uri(endpoint)
        uri = URI(endpoint)
        return uri if uri.path.end_with?("/chat/completions")

        uri.path = File.join(uri.path, "chat/completions")
        uri
      end

      def png_dimensions(bytes)
        return [4, 3] unless bytes.start_with?("\x89PNG\r\n\x1A\n".b) && bytes.bytesize >= 24

        bytes.byteslice(16, 8).unpack("NN")
      end

      def aspect_ratio(width, height)
        divisor = width.gcd(height)
        "#{width / divisor}:#{height / divisor}"
      end

      def supported_aspect_ratio(width, height)
        target = width.to_f / height
        supported = {
          "1:1" => 1.0,
          "2:3" => 2.0 / 3.0,
          "3:2" => 3.0 / 2.0,
          "3:4" => 3.0 / 4.0,
          "4:3" => 4.0 / 3.0,
          "4:5" => 4.0 / 5.0,
          "5:4" => 5.0 / 4.0,
          "9:16" => 9.0 / 16.0,
          "16:9" => 16.0 / 9.0,
          "21:9" => 21.0 / 9.0,
        }
        supported.min_by { |_ratio, value| (value - target).abs }.first
      end

      def extract_image_url(response)
        message = response.dig("choices", 0, "message") || {}
        images = message["images"]
        first_image = images&.first
        return nested_url(first_image) if first_image

        Array(message["content"]).each do |part|
          next unless part.is_a?(Hash)

          url = nested_url(part)
          return url if url
        end
        nil
      end

      def nested_url(payload)
        return payload if payload.is_a?(String)
        return nil unless payload.is_a?(Hash)

        payload.dig("image_url", "url") ||
          payload.dig("imageUrl", "url") ||
          payload["url"]
      end

      def decode_image_url(image_url)
        if image_url.start_with?("data:")
          encoded = image_url.split(",", 2).last
          raise "OpenRouter image data URL is malformed" unless encoded

          return encoded
        end

        Base64.strict_encode64(download_image(image_url))
      end

      def download_image(image_url)
        uri = URI(image_url)
        raise "OpenRouter returned an unsupported image URL: #{image_url[0, 120]}" unless %w[http https].include?(uri.scheme)

        request = Net::HTTP::Get.new(uri)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request)
        end
        raise "OpenRouter image download failed (#{response.code}): #{response.body.to_s[0, 200]}" unless response.is_a?(Net::HTTPSuccess)

        response.body
      end

      def post_json(payload)
        if @http_client
          return @http_client.call(@endpoint, payload, @api_key)
        end

        request = Net::HTTP::Post.new(@endpoint)
        request["Authorization"] = "Bearer #{@api_key}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)

        response = Net::HTTP.start(@endpoint.host, @endpoint.port, use_ssl: @endpoint.scheme == "https") do |http|
          http.request(request)
        end

        body = response.body.to_s
        raise "OpenRouter image request failed (#{response.code}): #{body[0, 500]}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(body)
      end
    end

    class ImageAspectNormalizer
      def initialize(bytes, extension:, target_width:, target_height:, background: "black")
        @bytes = bytes
        @extension = extension == "jpg" ? "jpg" : extension.to_s
        @target_width = target_width
        @target_height = target_height
        @background = background
      end

      def call
        return @bytes unless @target_width.positive? && @target_height.positive?
        return @bytes unless command_available?("identify") && command_available?("convert")

        with_tempfiles do |input, output|
          File.binwrite(input.path, @bytes)
          width, height = image_dimensions(input.path)
          return @bytes unless width&.positive? && height&.positive?
          return @bytes if same_aspect?(width, height)

          output_width, output_height = padded_size(width, height)
          convert(input.path, output.path, output_width, output_height)
          File.binread(output.path)
        end
      rescue StandardError
        @bytes
      end

      private

      def with_tempfiles
        Tempfile.create(["ai-graphics-source", ".#{@extension}"]) do |input|
          Tempfile.create(["ai-graphics-normalized", ".#{@extension}"]) do |output|
            yield input, output
          end
        end
      end

      def image_dimensions(path)
        stdout, _stderr, status = Open3.capture3("identify", "-format", "%w %h", path)
        return nil unless status.success?

        stdout.split.map(&:to_i)
      end

      def convert(input_path, output_path, output_width, output_height)
        _stdout, stderr, status = Open3.capture3(
          "convert",
          input_path,
          "-gravity",
          "center",
          "-background",
          @background,
          "-extent",
          "#{output_width}x#{output_height}",
          "+repage",
          output_path,
        )
        raise stderr unless status.success?
      end

      def command_available?(command)
        _stdout, _stderr, status = Open3.capture3("which", command)
        status.success?
      end

      def same_aspect?(width, height)
        width * @target_height == height * @target_width
      end

      def padded_size(width, height)
        if width * @target_height > height * @target_width
          [width, (width * @target_height.to_f / @target_width).ceil]
        else
          [(height * @target_width.to_f / @target_height).ceil, height]
        end
      end
    end

    class FramePngEncoder
      PALETTE = [
        [0, 0, 0],
        [0, 0, 215],
        [215, 0, 0],
        [215, 0, 215],
        [0, 215, 0],
        [0, 215, 215],
        [215, 215, 0],
        [215, 215, 215],
      ].freeze
      BRIGHT_PALETTE = [
        [0, 0, 0],
        [0, 0, 255],
        [255, 0, 0],
        [255, 0, 255],
        [0, 255, 0],
        [0, 255, 255],
        [255, 255, 0],
        [255, 255, 255],
      ].freeze

      def initialize(frame = nil, min_dimension: nil, **frame_keywords)
        @frame = frame || frame_keywords
        @min_dimension = min_dimension.to_i if min_dimension
      end

      def to_png
        png = +"\x89PNG\r\n\x1A\n".b
        png << chunk("IHDR", [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC"))
        png << chunk("IDAT", Zlib::Deflate.deflate(scanlines))
        png << chunk("IEND", "")
        png
      end

      private

      def width
        (base_width * scale).round
      end

      def height
        (base_height * scale).round
      end

      def scanlines
        data = +"".b
        height.times do |y|
          data << "\x00".b
          width.times do |x|
            source_x = [x / scale, base_width - 1].min.floor
            source_y = [y / scale, base_height - 1].min.floor
            row = @frame.fetch("rows")[source_y] || ""
            data << pixel_color(row.getbyte(source_x) == 49, attribute_at(source_x, source_y)).pack("C3")
          end
        end
        data
      end

      def base_width
        @frame.fetch("logical_width").to_i
      end

      def base_height
        [@frame.fetch("visible_height").to_i, @frame.fetch("logical_height").to_i].min
      end

      def scale
        return 1.0 unless @min_dimension&.positive?

        [1.0, @min_dimension.to_f / [base_width, base_height].min].max
      end

      def attribute_at(x, y)
        attributes = @frame.fetch("attributes", [])
        row = attributes[y / 8] || []
        row[x / 8] || { "ink" => 0, "paper" => 7, "bright" => false }
      end

      def pixel_color(on, attr)
        palette = attr["bright"] ? BRIGHT_PALETTE : PALETTE
        palette[(on ? attr.fetch("ink", 0) : attr.fetch("paper", 7)).to_i & 7]
      end

      def chunk(type, data)
        [data.bytesize, type, data, Zlib.crc32(type + data)].pack("NA4A*N")
      end
    end
  end
end
