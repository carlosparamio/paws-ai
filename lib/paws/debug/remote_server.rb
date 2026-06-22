# frozen_string_literal: true

require "cgi"
require "json"
require "socket"
require "uri"

module PAWS
  module Debug
    class RemoteServer
      JSON_TYPE = "application/json; charset=utf-8"
      HTML_TYPE = "text/html; charset=utf-8"

      def initialize(registry:, logger: nil)
        @registry = registry
        @logger = logger || ->(_message) {}
        @server = nil
        @thread = nil
        @bind = nil
        @port = nil
      end

      def start_async(port:, bind: "127.0.0.1")
        @bind = bind
        @port = port
        @server = TCPServer.new(bind, port)
        @thread = Thread.new { serve_forever }
        @logger.call("PAWS remote debugger: http://#{bind}:#{port}")
        self
      end

      def shutdown
        @server&.close
        @thread&.join(1)
      end

      private

      def serve_forever
        loop do
          client = @server.accept
          Thread.new(client) { |socket| handle_client(socket) }
        end
      rescue IOError, Errno::EBADF
        nil
      rescue StandardError => e
        @logger.call("[remote-debug] #{e.class}: #{e.message}")
      end

      def handle_client(socket)
        request = read_request(socket)
        status, type, body = route(request)
        write_response(socket, status, type, body)
      rescue StandardError => e
        @logger.call("[remote-debug] request failed: #{e.class}: #{e.message}")
        write_response(socket, 500, JSON_TYPE, JSON.generate("error" => e.message))
      ensure
        socket&.close
      end

      def read_request(socket)
        request_line = socket.gets&.strip
        raise ArgumentError, "Empty request" if request_line.to_s.empty?

        method, target, = request_line.split(/\s+/, 3)
        headers = {}
        while (line = socket.gets)
          line = line.chomp
          break if line.empty?

          key, value = line.split(":", 2)
          headers[key.downcase] = value.to_s.strip if key
        end
        length = headers.fetch("content-length", "0").to_i
        body = length.positive? ? socket.read(length).to_s : ""
        uri = URI.parse(target)
        {
          method: method,
          path: uri.path,
          query: URI.decode_www_form(uri.query.to_s).to_h,
          body: body,
        }
      end

      def route(request)
        case [request[:method], request[:path]]
        when ["GET", "/"]
          [200, HTML_TYPE, index_html]
        when ["GET", "/api/debug/state"]
          handle_state(request)
        when ["POST", "/api/debug/command"]
          handle_command(request)
        else
          json_error(404, "Not found")
        end
      end

      def handle_state(request)
        controller = controller_for(request)
        json_payload(state_payload(controller))
      rescue KeyError => e
        json_error(404, e.message)
      end

      def handle_command(request)
        payload = parse_json_body(request[:body])
        controller = controller_for(request, payload)
        command = payload.fetch("command", "")
        json_payload(controller.execute(command).merge("sessions" => @registry.sessions))
      rescue JSON::ParserError => e
        json_error(400, e.message)
      rescue KeyError => e
        json_error(404, e.message)
      end

      def controller_for(request, payload = {})
        session_id = request[:query]["session_id"] || payload["session_id"]
        controller = session_id ? @registry.find(session_id) : @registry.current
        raise KeyError, "No debug session available" unless controller

        controller
      end

      def state_payload(controller)
        {
          "sessions" => @registry.sessions,
          "current" => controller&.state,
        }
      end

      def parse_json_body(body)
        return {} if body.to_s.empty?

        JSON.parse(body)
      end

      def json_payload(payload, status: 200)
        [status, JSON_TYPE, JSON.generate(payload)]
      end

      def json_error(status, message)
        json_payload({ "error" => message }, status: status)
      end

      def write_response(socket, status, content_type, body)
        reason = {
          200 => "OK",
          400 => "Bad Request",
          404 => "Not Found",
          405 => "Method Not Allowed",
          500 => "Internal Server Error",
        }.fetch(status, "OK")
        bytes = body.to_s.b
        socket.write "HTTP/1.1 #{status} #{reason}\r\n"
        socket.write "Content-Type: #{content_type}\r\n"
        socket.write "Content-Length: #{bytes.bytesize}\r\n"
        socket.write "Connection: close\r\n"
        socket.write "\r\n"
        socket.write bytes
      end

      def index_html
        <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
            <meta charset="utf-8">
            <title>PAWS Remote Debugger</title>
            <style>
              :root { color-scheme: dark; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
              body { margin: 0; background: #080b0f; color: #d8f3ff; }
              main { display: grid; grid-template-rows: auto 1fr auto; height: 100vh; }
              header, form { padding: 12px 16px; background: #111823; border-bottom: 1px solid #263649; }
              h1 { font-size: 18px; margin: 0 0 6px; }
              #status { color: #7dd3fc; }
              #sessions { color: #9ca3af; font-size: 13px; }
              pre { margin: 0; padding: 16px; overflow: auto; white-space: pre-wrap; line-height: 1.35; }
              form { display: flex; gap: 8px; border-bottom: 0; border-top: 1px solid #263649; }
              input { flex: 1; background: #020617; color: #e5e7eb; border: 1px solid #334155; padding: 10px; font: inherit; }
              button { background: #0369a1; color: white; border: 0; padding: 0 16px; font: inherit; }
            </style>
          </head>
          <body>
            <main>
              <header>
                <h1>PAWS Remote Debugger</h1>
                <div id="status">Connecting...</div>
                <div id="sessions"></div>
              </header>
              <pre id="output"></pre>
              <form id="commandForm">
                <input id="command" autocomplete="off" autofocus placeholder="p, f, s, c, b P1B5, autoplay file all">
                <button type="submit">Run</button>
              </form>
            </main>
            <script>
              const statusEl = document.getElementById("status");
              const sessionsEl = document.getElementById("sessions");
              const outputEl = document.getElementById("output");
              const commandEl = document.getElementById("command");
              const form = document.getElementById("commandForm");
              let lastLogSize = 0;

              function focusCommand() {
                commandEl.focus({ preventScroll: true });
              }

              function renderState(payload) {
                const current = payload.current || {};
                const state = current.engine || {};
                const bp = current.breakpoint || {};
                statusEl.textContent = `${current.status || "none"} loc=${state.location ?? "-"} turns=${state.turns ?? "-"} step=${state.stepping ? "on" : "off"}`;
                if (bp.process !== undefined) {
                  statusEl.textContent += ` breakpoint=P${String(bp.process).padStart(3, "0")} B${String(bp.block).padStart(3, "0")} C${String(bp.condact).padStart(3, "0")} ${bp.reason || ""}`;
                }
                sessionsEl.textContent = (payload.sessions || []).map((s) => `${s.session_id}:${s.status}:${s.game}`).join(" | ");
                const log = current.log || [];
                if (log.length !== lastLogSize) {
                  outputEl.textContent = log.map((entry) => entry.output).join("\\n");
                  outputEl.scrollTop = outputEl.scrollHeight;
                  lastLogSize = log.length;
                }
              }

              async function refresh() {
                try {
                  const response = await fetch("/api/debug/state");
                  renderState(await response.json());
                } catch (error) {
                  statusEl.textContent = `Error: ${error}`;
                }
              }

              form.addEventListener("submit", async (event) => {
                event.preventDefault();
                const command = commandEl.value;
                commandEl.value = "";
                const response = await fetch("/api/debug/command", {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({ command }),
                });
                const payload = await response.json();
                if (payload.error) outputEl.textContent += payload.error;
                renderState({ current: payload.state, sessions: payload.sessions || [] });
                focusCommand();
              });

              setInterval(refresh, 750);
              refresh();
              focusCommand();
            </script>
          </body>
          </html>
        HTML
      end
    end
  end
end
