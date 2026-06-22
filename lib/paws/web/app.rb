# frozen_string_literal: true

require "json"
require "securerandom"
require "socket"
require_relative "../game_data/serializer"
require_relative "ai_graphics_enhancer"
require_relative "graphics_presenter"
require_relative "protocol"
require_relative "session"

module PAWS
  module Web
    # Minimal stdlib HTTP prototype for the PAWS web UI.
    #
    # It deliberately avoids external web dependencies for the first vertical
    # slice. The API shapes are compatible with the WebSocket-oriented
    # SPEC_WEB_UI and can be moved behind Rack/WebSocket later.
    class App
      PUBLIC_DIR = File.expand_path("../../../web", __dir__)
      CACHE_ROOT = File.expand_path("../../../cache", __dir__)

      def initialize(game_path:, mapping: nil, engine_options: {}, session_options: {}, debug_registry: nil, debug_logger: nil)
        @game_path = game_path
        @mapping = mapping
        @engine_options = engine_options
        @session_options = session_options
        @debug_registry = debug_registry
        @debug_logger = debug_logger || ->(_message) {}
        @game_data = load_game_data(game_path)
        @graphics = GraphicsPresenter.new(@game_data)
        @ai_graphics = build_ai_graphics
        @sessions = {}
      end

      def start(port: 4567, bind: "127.0.0.1")
        server = TCPServer.new(bind, port)
        trap("INT") { server.close }

        loop do
          socket = server.accept
          handle_socket(socket)
        rescue IOError
          break
        end
      end

      private

      attr_reader :game_data, :graphics

      def handle_socket(socket)
        request_line = socket.gets
        return socket.close unless request_line

        method, raw_path, = request_line.split
        headers = consume_headers(socket)
        body = read_body(socket, headers)

        unless %w[GET POST].include?(method)
          return write_response(socket, 405, "text/plain", "Method not allowed")
        end

        status, content_type, response_body = route(method, raw_path || "/", body)
        write_response(socket, status, content_type, response_body)
      ensure
        socket.close unless socket.closed?
      end

      def consume_headers(socket)
        headers = {}
        loop do
          line = socket.gets
          break if line.nil? || line == "\r\n"

          key, value = line.split(":", 2)
          headers[key.downcase] = value.strip if key && value
        end
        headers
      end

      def read_body(socket, headers)
        length = headers.fetch("content-length", "0").to_i
        return "" unless length.positive?

        socket.read(length)
      end

      def route(method, raw_path, body)
        path = raw_path.split("?", 2).first
        case [method, path]
        when ["GET", "/api/session"]
          ok_json(Protocol.session_ready(
            session_id: SecureRandom.hex(8),
            game: game_title,
            debug: debug_output?,
            remote_debug: remote_debug?,
            text_renderer: @session_options.fetch(:text_renderer, "pc"),
            graphics_mode: @session_options.fetch(:graphics_mode, "original"),
            font_size: @session_options[:font_size],
          ))
        when ["POST", "/api/sessions"]
          JSON.parse(body) unless body.empty?
          session = create_session
          ok_json({ "events" => session.start, "snapshot" => session.snapshot })
        when ["GET", "/api/pictures"]
          ok_json({ "picture_ids" => graphics.picture_ids })
        else
          if method == "GET" && path =~ %r{\A/api/pictures/(\d+)/frame\z}
            ok_json(graphics.frame_for_picture(Regexp.last_match(1).to_i))
          elsif method == "GET" && path =~ %r{\A/api/ai-graphics/([^/]+)/([^/]+)/pic(\d+)/status\z}
            ai_graphics_status(Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3))
          elsif method == "GET" && path =~ %r{\A/cache/([^/]+)/([^/]+)/pic(\d+)\.(jpg|jpeg|png|webp)\z}
            ai_graphics_image(Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3), Regexp.last_match(4))
          elsif method == "POST" && path =~ %r{\A/api/sessions/([^/]+)/input\z}
            submit_input(Regexp.last_match(1), body)
          elsif method == "POST" && path =~ %r{\A/api/sessions/([^/]+)/timeout\z}
            submit_timeout(Regexp.last_match(1))
          elsif method == "POST" && path =~ %r{\A/api/sessions/([^/]+)/key\z}
            submit_key(Regexp.last_match(1), body)
          elsif method == "GET" && path =~ %r{\A/api/sessions/([^/]+)/debug-state\z}
            debug_state(Regexp.last_match(1))
          elsif method == "GET"
            static_response(path)
          else
            [404, "application/json", JSON.generate(Protocol.error("Not found"))]
          end
        end
      rescue KeyError => e
        [404, "application/json", JSON.generate(Protocol.error(e.message))]
      rescue StandardError => e
        warn("[web] #{e.class}: #{e.message}\n#{e.backtrace&.first(8)&.join("\n")}") if debug_output?
        [500, "application/json", JSON.generate(Protocol.error(e.message))]
      end

      def ok_json(payload)
        [200, "application/json", JSON.generate(payload)]
      end

      def create_session
        id = SecureRandom.hex(8)
        session_options = @session_options.reject { |key, _| %i[graphics_cache].include?(key) }
        @sessions[id] = Session.new(
          id: id,
          game_data: game_data,
          game_name: game_title,
          engine_options: @engine_options,
          ai_graphics: @ai_graphics,
          debug_controller_factory: debug_controller_factory,
          **session_options,
        )
      end

      def submit_input(session_id, body)
        session = @sessions.fetch(session_id)
        payload = body.empty? ? {} : JSON.parse(body)
        input = payload.fetch("text", "")
        ok_json({ "events" => session.submit(input), "snapshot" => session.snapshot })
      rescue JSON::ParserError => e
        [400, "application/json", JSON.generate(Protocol.error(e.message))]
      end

      def submit_timeout(session_id)
        session = @sessions.fetch(session_id)
        ok_json({ "events" => session.timeout, "snapshot" => session.snapshot })
      end

      def submit_key(session_id, body)
        session = @sessions.fetch(session_id)
        payload = body.empty? ? {} : JSON.parse(body)
        key = payload.fetch("key", "")
        ok_json({ "events" => session.submit_key(key), "snapshot" => session.snapshot })
      rescue JSON::ParserError => e
        [400, "application/json", JSON.generate(Protocol.error(e.message))]
      end

      def debug_state(session_id)
        session = @sessions.fetch(session_id)
        ok_json({ "events" => [session.debug_status_event].compact, "snapshot" => session.snapshot })
      end

      def static_response(path)
        relative = path == "/" ? "index.html" : path.sub(%r{\A/}, "")
        return [403, "text/plain", "Forbidden"] if relative.include?("..")

        file_path = File.join(PUBLIC_DIR, relative)
        return [404, "text/plain", "Not found"] unless File.file?(file_path)

        [200, content_type(file_path), File.binread(file_path)]
      end

      def ai_graphics_status(game_slug, style, picture_id)
        return [404, "application/json", JSON.generate(Protocol.error("AI graphics disabled"))] unless @ai_graphics
        return [404, "application/json", JSON.generate(Protocol.error("Unknown AI graphics cache"))] unless matching_ai_graphics_path?(game_slug, style)

        ok_json(@ai_graphics.status_for(picture_id))
      end

      def ai_graphics_image(game_slug, style, picture_id, extension)
        return [404, "text/plain", "Not found"] unless @ai_graphics && matching_ai_graphics_path?(game_slug, style)

        path = @ai_graphics.cached_path(picture_id, style: style)
        return [404, "text/plain", "Not found"] unless File.extname(path).delete_prefix(".") == extension
        return [404, "text/plain", "Not found"] unless File.file?(path)

        [200, image_content_type(path), File.binread(path)]
      end

      def image_content_type(path)
        case File.extname(path).downcase
        when ".png" then "image/png"
        when ".webp" then "image/webp"
        else "image/jpeg"
        end
      end

      def content_type(path)
        case File.extname(path)
        when ".html" then "text/html; charset=utf-8"
        when ".css" then "text/css; charset=utf-8"
        when ".js" then "text/javascript; charset=utf-8"
        when ".json" then "application/json"
        else "application/octet-stream"
        end
      end

      def write_response(socket, status, content_type, body)
        reason = { 200 => "OK", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed", 500 => "Internal Server Error" }.fetch(status, "OK")
        socket.write "HTTP/1.1 #{status} #{reason}\r\n"
        socket.write "Content-Type: #{content_type}\r\n"
        socket.write "Content-Length: #{body.bytesize}\r\n"
        socket.write "Connection: close\r\n"
        socket.write "\r\n"
        socket.write body
      end

      def game_title
        game_data.dig("game_info", "title") ||
          game_data.dig("game", "title") ||
          File.basename(@game_path, File.extname(@game_path))
      end

      def debug_output?
        (@engine_options[:debug_mode] && @debug_registry.nil?) || @engine_options.fetch(:verbosity, 0).positive?
      end

      def remote_debug?
        !@debug_registry.nil?
      end

      def debug_controller_factory
        return nil unless @debug_registry

        lambda do |engine, id:, game_name:|
          controller = PAWS::Debug::RemoteController.new(
            engine,
            id: id,
            game_name: game_name,
            logger: @debug_logger,
          )
          @debug_registry.register(controller)
          controller
        end
      end

      def build_ai_graphics
        graphics_mode = @session_options.fetch(:graphics_mode, "original").to_s
        ai_style = graphics_mode.delete_prefix("ai-") if graphics_mode.start_with?("ai-")
        return nil unless ai_style

        AIGraphicsEnhancer.new(
          game_slug: File.basename(@game_path, File.extname(@game_path)),
          cache_root: CACHE_ROOT,
          style: ai_style || AIGraphicsEnhancer::DEFAULT_STYLE,
          cache_only: @session_options[:graphics_cache],
          logger: ->(message) { warn(message) if debug_output? },
        )
      end

      def matching_ai_graphics_path?(game_slug, style)
        @ai_graphics.game_slug == AIGraphicsEnhancer.safe_slug(game_slug) &&
          @ai_graphics.matches_public_style?(style)
      end

      def load_game_data(path)
        ext = File.extname(path).downcase
        case ext
        when ".json"
          JSON.parse(File.read(path))
        when ".sna", ".z80", ".sp"
          PAWS::Extractor.new(mapping: snapshot_mapping(path)).extract(path)
        else
          raise ArgumentError, "Unsupported file format: #{ext}"
        end
      end

      def snapshot_mapping(path)
        return @mapping if @mapping

        candidate = path.sub(/#{Regexp.escape(File.extname(path))}\z/i, ".mapping.json")
        File.file?(candidate) ? candidate : nil
      end
    end
  end
end
