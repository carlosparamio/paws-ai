# frozen_string_literal: true

require "spec_helper"
require "paws/web/ai_graphics_enhancer"
require "tmpdir"

RSpec.describe PAWS::Web::AIGraphicsEnhancer do
  let(:openai_config) do
    {
      api_key: "key",
      provider: "openai",
      endpoint: "https://api.openai.test/v1/images/edits",
      model: "image-model",
    }
  end
  let(:openrouter_config) do
    {
      api_key: "key",
      provider: "openrouter",
      endpoint: "https://openrouter.ai/api/v1",
      model: "google/gemini-2.5-flash-image",
    }
  end
  let(:frame) do
    {
      "type" => "screen.frame",
      "picture_id" => 1,
      "logical_width" => 256,
      "logical_height" => 192,
      "visible_height" => 96,
      "rows" => Array.new(96) { "0" * 256 },
      "attributes" => Array.new(24) { Array.new(32) { { "ink" => 7, "paper" => 0, "bright" => false } } },
    }
  end

  it "uses cached art when present" do
    Dir.mktmpdir do |dir|
      enhancer = described_class.new(game_slug: "sample.sna", cache_root: dir, style: "pixelart", **openai_config)
      FileUtils.mkdir_p(File.dirname(enhancer.cached_path(1)))
      File.binwrite(enhancer.cached_path(1), "jpeg")

      decorated = enhancer.decorate_frame(frame, description: "A room")

      expect(decorated.fetch("ai_graphics")).to include(
        "state" => "ready",
        "style" => "pixelart",
        "provider" => "openai",
      )
      expect(decorated.fetch("ai_graphics").fetch("url")).to include("/cache/sample/pixelart/pic1.jpg")
    end
  end

  it "uses existing PNG cache files and advertises their real extension" do
    Dir.mktmpdir do |dir|
      enhancer = described_class.new(game_slug: "sample.sna", cache_root: dir, style: "realistic", **openai_config)
      png_path = File.join(dir, "sample", "realistic", "pic1.png")
      FileUtils.mkdir_p(File.dirname(png_path))
      File.binwrite(png_path, "\x89PNG\r\n\x1A\n".b)

      decorated = enhancer.decorate_frame(frame, description: "A room")

      expect(decorated.fetch("ai_graphics").fetch("cache_path")).to eq(png_path)
      expect(decorated.fetch("ai_graphics").fetch("url")).to include("/cache/sample/realistic/pic1.png")
    end
  end

  it "reports pending and enqueues generation when cache is missing" do
    Dir.mktmpdir do |dir|
      enhancer = described_class.new(game_slug: "sample.sna", cache_root: dir, **openai_config)

      decorated = enhancer.decorate_frame(frame, description: "A room")

      expect(decorated.fetch("ai_graphics")).to include("state" => "pending")
      expect(decorated.fetch("ai_graphics").fetch("status_url")).to eq("/api/ai-graphics/sample/pixelart/pic1/status")
    end
  end

  it "can use cached graphics without requiring AI provider configuration" do
    Dir.mktmpdir do |dir|
      enhancer = described_class.new(game_slug: "sample.sna", cache_root: dir, style: "realistic", cache_only: true)
      png_path = File.join(dir, "sample", "realistic", "pic1.png")
      FileUtils.mkdir_p(File.dirname(png_path))
      File.binwrite(png_path, "\x89PNG\r\n\x1A\n".b)

      decorated = enhancer.decorate_frame(frame, description: "A room")

      expect(decorated.fetch("ai_graphics")).to include(
        "state" => "ready",
        "style" => "realistic",
        "cache_path" => png_path,
      )
      expect(decorated.fetch("ai_graphics")).not_to have_key("provider")
      expect(decorated.fetch("ai_graphics")).not_to have_key("model")
    end
  end

  it "leaves the PAWS frame untouched on cache miss in cached-only mode" do
    Dir.mktmpdir do |dir|
      enhancer = described_class.new(game_slug: "sample.sna", cache_root: dir, cache_only: true)

      decorated = enhancer.decorate_frame(frame, description: "A room")

      expect(decorated).to eq(frame)
      expect(enhancer.status_for(1)).to include("state" => "missing")
    end
  end

  it "uses explicit OpenRouter configuration when selected as graphics provider" do
    old_value = ENV["AI_GRAPHICS_MAX_TOKENS"]
    ENV["AI_GRAPHICS_MAX_TOKENS"] = "2048"
    Dir.mktmpdir do |dir|
      enhancer = described_class.new(game_slug: "sample.sna", cache_root: dir, **openrouter_config)

      expect(enhancer.provider).to eq("openrouter")
      expect(enhancer.model).to eq("google/gemini-2.5-flash-image")
    end
  ensure
    ENV["AI_GRAPHICS_MAX_TOKENS"] = old_value
  end

  it "requires an explicit AI graphics provider" do
    Dir.mktmpdir do |dir|
      expect do
        described_class.new(game_slug: "sample.sna", cache_root: dir, api_key: "key", endpoint: "https://openrouter.ai/api/v1/chat/completions", model: "model")
      end.to raise_error(ArgumentError, /AI_GRAPHICS_PROVIDER/)
    end
  end

  it "requires explicit AI graphics endpoint and model" do
    Dir.mktmpdir do |dir|
      expect do
        described_class.new(game_slug: "sample.sna", cache_root: dir, api_key: "key", provider: "openai", endpoint: nil, model: "model")
      end.to raise_error(ArgumentError, /AI_GRAPHICS_ENDPOINT/)

      expect do
        described_class.new(game_slug: "sample.sna", cache_root: dir, api_key: "key", provider: "openai", endpoint: "https://api.example.test", model: nil)
      end.to raise_error(ArgumentError, /AI_GRAPHICS_MODEL/)
    end
  end

  it "requires max tokens for OpenRouter" do
    old_value = ENV["AI_GRAPHICS_MAX_TOKENS"]
    ENV.delete("AI_GRAPHICS_MAX_TOKENS")
    Dir.mktmpdir do |dir|
      expect do
        described_class.new(game_slug: "sample.sna", cache_root: dir, **openrouter_config)
      end.to raise_error(ArgumentError, /AI_GRAPHICS_MAX_TOKENS/)
    end
  ensure
    ENV["AI_GRAPHICS_MAX_TOKENS"] = old_value
  end

  it "asks the pixelart style for a modern high-detail reinterpretation" do
    Dir.mktmpdir do |dir|
      enhancer = described_class.new(game_slug: "sample.sna", cache_root: dir, style: "pixelart", **openai_config)

      prompt = enhancer.send(:prompt_for, "A cold room", frame: frame)

      expect(prompt).to match(/modern high-resolution pixel art/i)
      expect(prompt).to include("controlled dithering")
      expect(prompt).to include("do not merely upscale")
    end
  end

  it "instructs every style to redraw from scratch and not copy prose into the image" do
    Dir.mktmpdir do |dir|
      enhancer = described_class.new(game_slug: "sample.sna", cache_root: dir, style: "painting", **openai_config)

      prompt = enhancer.send(:prompt_for, "Salidas: Norte y Oeste. Hay una puerta.", frame: frame)

      expect(prompt).to include("redraw the scene from scratch")
      expect(prompt).to include("Do not trace, upscale, pixel-clean")
      expect(prompt).to include("Do not write any readable words")
      expect(prompt).to include("Use the location description only as semantic inspiration")
    end
  end

  it "logs received and normalized image dimensions while generating" do
    Dir.mktmpdir do |dir|
      logs = []
      generated_png = PAWS::Web::FramePngEncoder.new(
        "logical_width" => 1,
        "logical_height" => 1,
        "visible_height" => 1,
        "rows" => ["1"],
        "attributes" => [[{ "ink" => 7, "paper" => 0, "bright" => false }]],
      ).to_png
      enhancer = described_class.new(game_slug: "sample.sna", cache_root: dir, logger: ->(message) { logs << message }, **openai_config)
      fake_client = double("image_client")
      allow(fake_client).to receive(:edit).and_return("b64_json" => Base64.strict_encode64(generated_png))
      allow(enhancer).to receive(:image_client).and_return(fake_client)

      enhancer.generate_frame(frame, description: "A room", force: true)

      expect(logs.join("\n")).to include("reference sample/pixelart/pic1 dimensions=683x256")
      expect(logs.join("\n")).to include("received sample/pixelart/pic1 format=png dimensions=1x1 target=256x96")
      expect(logs.join("\n")).to match(/normalized sample\/pixelart\/pic1 dimensions=\d+x\d+/)
    end
  end

  it "uses the dominant visible paper colour as AI aspect padding background" do
    Dir.mktmpdir do |dir|
      enhancer = described_class.new(game_slug: "sample.sna", cache_root: dir, logger: ->(_message) {}, **openai_config)
      blue_frame = frame.merge(
        "attributes" => Array.new(24) { Array.new(32) { { "ink" => 7, "paper" => 1, "bright" => false } } },
      )

      expect(enhancer.send(:dominant_paper_background, blue_frame)).to eq("#0000d7")
    end
  end
end

RSpec.describe PAWS::Web::OpenRouterImageClient do
  it "posts chat-completions image requests and extracts base64 image data" do
    captured = nil
    client = described_class.new(
      api_key: "key",
      endpoint: "https://openrouter.ai/api/v1",
      max_tokens: 2048,
      http_client: lambda do |endpoint, payload, api_key|
        captured = { endpoint: endpoint, payload: payload, api_key: api_key }
        {
          "choices" => [
            {
              "message" => {
                "images" => [
                  { "imageUrl" => { "url" => "data:image/jpeg;base64,#{Base64.strict_encode64("jpeg")}" } },
                ],
              },
            },
          ],
        }
      end,
    )

    source_png = PAWS::Web::FramePngEncoder.new(
      "logical_width" => 256,
      "logical_height" => 192,
      "visible_height" => 96,
      "rows" => Array.new(96) { "0" * 256 },
      "attributes" => Array.new(24) { Array.new(32) { { "ink" => 7, "paper" => 0, "bright" => false } } },
    ).to_png

    response = client.edit(model: "google/gemini-2.5-flash-image", prompt: "Draw this", source_png: source_png)

    expect(Base64.decode64(response.fetch("b64_json"))).to eq("jpeg")
    expect(captured.fetch(:endpoint).to_s).to eq("https://openrouter.ai/api/v1/chat/completions")
    expect(captured.fetch(:api_key)).to eq("key")
    expect(captured.fetch(:payload)).to include(
      model: "google/gemini-2.5-flash-image",
      modalities: %w[image],
      max_tokens: 2048,
      stream: false,
    )
    expect(captured.fetch(:payload).dig(:messages, 0, :content, 0)).to eq(type: "text", text: "Draw this")
    expect(captured.fetch(:payload).dig(:messages, 0, :content, 1, :image_url, :url)).to start_with("data:image/png;base64,")
    expect(captured.fetch(:payload).dig(:image_config, :aspect_ratio)).to eq("21:9")
  end

  it "passes an explicit OpenRouter image size when configured" do
    captured = nil
    client = described_class.new(
      api_key: "key",
      endpoint: "https://openrouter.ai/api/v1",
      max_tokens: 2048,
      image_size: "2K",
      http_client: lambda do |_endpoint, payload, _api_key|
        captured = payload
        {
          "choices" => [
            {
              "message" => {
                "images" => [
                  { "imageUrl" => { "url" => "data:image/jpeg;base64,#{Base64.strict_encode64("jpeg")}" } },
                ],
              },
            },
          ],
        }
      end,
    )
    source_png = PAWS::Web::FramePngEncoder.new(
      "logical_width" => 256,
      "logical_height" => 192,
      "visible_height" => 96,
      "rows" => Array.new(96) { "0" * 256 },
      "attributes" => Array.new(24) { Array.new(32) { { "ink" => 7, "paper" => 0, "bright" => false } } },
    ).to_png

    client.edit(model: "google/gemini-2.5-flash-image", prompt: "Draw this", source_png: source_png)

    expect(captured.dig(:image_config, :image_size)).to eq("2K")
  end
end

RSpec.describe PAWS::Web::FramePngEncoder do
  it "encodes a browser frame as a PNG reference image" do
    frame = {
      "logical_width" => 1,
      "logical_height" => 1,
      "visible_height" => 1,
      "rows" => ["1"],
      "attributes" => [[{ "ink" => 7, "paper" => 0, "bright" => false }]],
    }

    png = described_class.new(frame).to_png

    expect(png.bytes.first(8)).to eq([137, 80, 78, 71, 13, 10, 26, 10])
  end

  it "preserves bitmap row pixels in the PNG payload" do
    frame = {
      "logical_width" => 1,
      "logical_height" => 1,
      "visible_height" => 1,
      "rows" => ["1"],
      "attributes" => [[{ "ink" => 7, "paper" => 0, "bright" => false }]],
    }

    png = described_class.new(frame).to_png
    idat = +""
    offset = 8
    while offset < png.bytesize
      length = png.byteslice(offset, 4).unpack1("N")
      type = png.byteslice(offset + 4, 4)
      data = png.byteslice(offset + 8, length)
      idat << data if type == "IDAT"
      offset += 12 + length
    end

    scanline = Zlib::Inflate.inflate(idat)

    expect(scanline.bytes).to eq([0, 215, 215, 215])
  end

  it "can upscale the reference PNG to satisfy provider minimum dimensions" do
    frame = {
      "logical_width" => 256,
      "logical_height" => 192,
      "visible_height" => 96,
      "rows" => Array.new(96) { "0" * 256 },
      "attributes" => Array.new(24) { Array.new(32) { { "ink" => 7, "paper" => 0, "bright" => false } } },
    }

    png = described_class.new(frame, min_dimension: 256).to_png

    expect(png.byteslice(16, 8).unpack("NN")).to eq([683, 256])
  end
end
