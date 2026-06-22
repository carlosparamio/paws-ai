# frozen_string_literal: true

require "spec_helper"
require "paws/web/ai_graphics_pregenerator"
require "tmpdir"

RSpec.describe PAWS::Web::AIGraphicsPregenerator do
  let(:game_data) do
    {
      "game" => { "paw_version" => 2 },
      "defaults" => { "ink" => 7, "paper" => 0 },
      "locations" => [
        { "id" => 1, "description" => "A cold room." },
        { "id" => 3, "description" => "A room with a hidden door." },
      ],
      "pictures" => {
        "entries" => [
          {
            "id" => 1,
            "drawable" => true,
            "ink" => 7,
            "paper" => 0,
            "decoded_commands" => [
              { "family" => 0, "name" => "plot", "x" => 1, "y" => 1 },
            ],
          },
          {
            "id" => 2,
            "drawable" => true,
            "ink" => 7,
            "paper" => 0,
            "decoded_commands" => [],
          },
          {
            "id" => 7,
            "drawable" => true,
            "ink" => 7,
            "paper" => 0,
            "decoded_commands" => [
              { "family" => 0, "name" => "plot", "x" => 2, "y" => 2 },
            ],
          },
        ],
      },
      "processes" => [
        {
          "id" => 1,
          "entries" => [
            {
              "verb_name" => "*",
              "noun_name" => "*",
              "condacts" => [
                { "name" => "AT", "params" => [3] },
                { "name" => "PICTURE", "params" => [7] },
              ],
            },
          ],
        },
      ],
    }
  end

  around do |example|
    old_env = ENV.to_h.slice("AI_GRAPHICS_API_KEY", "AI_GRAPHICS_PROVIDER", "AI_GRAPHICS_ENDPOINT", "AI_GRAPHICS_MODEL")
    ENV["AI_GRAPHICS_API_KEY"] = "key"
    ENV["AI_GRAPHICS_PROVIDER"] = "openai"
    ENV["AI_GRAPHICS_ENDPOINT"] = "https://api.openai.test/v1/images/edits"
    ENV["AI_GRAPHICS_MODEL"] = "image-model"
    example.run
  ensure
    %w[AI_GRAPHICS_API_KEY AI_GRAPHICS_PROVIDER AI_GRAPHICS_ENDPOINT AI_GRAPHICS_MODEL].each do |name|
      old_env.key?(name) ? ENV[name] = old_env[name] : ENV.delete(name)
    end
  end

  it "targets rendered pictures and attaches matching location descriptions" do
    Dir.mktmpdir do |dir|
      game_path = File.join(dir, "game.json")
      File.write(game_path, JSON.generate(game_data))
      pregenerator = described_class.new(game_path: game_path, cache_root: dir, logger: ->(_message) {})

      targets = pregenerator.targets

      expect(targets.map(&:picture_id)).to eq([1, 7])
      expect(targets.first.location_id).to eq(1)
      expect(targets.first.description).to eq("A cold room.")
    end
  end

  it "infers picture context from AT and PICTURE condacts before falling back to matching ids" do
    Dir.mktmpdir do |dir|
      game_path = File.join(dir, "game.json")
      File.write(game_path, JSON.generate(game_data))
      pregenerator = described_class.new(game_path: game_path, cache_root: dir, logger: ->(_message) {})

      target = pregenerator.targets.find { |candidate| candidate.picture_id == 7 }

      expect(target.location_id).to eq(3)
      expect(target.location_ids).to eq([3])
      expect(target.inference).to eq("condacts")
      expect(target.description).to eq("A room with a hidden door.")
    end
  end

  it "generates missing cache files synchronously" do
    Dir.mktmpdir do |dir|
      game_path = File.join(dir, "game.json")
      File.write(game_path, JSON.generate(game_data))
      pregenerator = described_class.new(game_path: game_path, cache_root: dir, logger: ->(_message) {})
      fake_client = double("image_client")
      allow(fake_client).to receive(:edit).and_return("b64_json" => Base64.strict_encode64("jpeg"))
      allow(pregenerator.enhancer).to receive(:image_client).and_return(fake_client)

      summary = pregenerator.run

      expect(summary).to include(total: 2, generated: 2, skipped: 0, failed: 0)
      expect(File.binread(pregenerator.targets.first.cache_path)).to eq("jpeg")
    end
  end
end
