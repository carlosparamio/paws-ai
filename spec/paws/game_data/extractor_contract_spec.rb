# frozen_string_literal: true

require "spec_helper"
require "digest"
require "json"
require "paws/game_data/extractor"

RSpec.describe "PAWS extractor contracts" do
  # The "El Espía" snapshot ships with the public repository; its
  # extraction hash is pinned here as a regression guard. Other game
  # contracts live under `.agents/specs/`.
  ESPIA_HASH = "af487f7b61276429513428d4052823dc4f46f904229ad390f25bbddaaf80968a".freeze

  def canonical_json(value)
    JSON.generate(deep_sort(value))
  end

  def deep_sort(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) do |key, sorted|
        sorted[key] = deep_sort(value[key])
      end
    when Array
      value.map { |item| deep_sort(item) }
    else
      value
    end
  end

  it "keeps the bundled El Espía extraction compatible with its contract hash" do
    extracted = PAWS::Extractor.new.extract(File.expand_path("../../../games/espia.sna", __dir__))

    actual_hash = Digest::SHA256.hexdigest(canonical_json(extracted))

    expect(actual_hash).to eq(ESPIA_HASH)
  end
end
