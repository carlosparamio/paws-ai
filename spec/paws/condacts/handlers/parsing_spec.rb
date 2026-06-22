# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::CondactHandlers::Parsing do
  let(:registry) { PAWS::CondactRegistry.new }
  let(:engine) do
    instance_double(
      PAWS::Engine,
      quoted_buffer: quoted_buffer,
      clear_parsed_state: nil,
      parse_input: nil,
      store_parsed_words: nil,
      log_parser_result: nil,
    )
  end
  let(:quoted_buffer) { "new command" }

  before do
    described_class.register(registry, engine)
  end

  it "reparses the quoted buffer through the engine" do
    expect(registry.call("PARSE")).to eq(:continue_scan)

    expect(engine).to have_received(:clear_parsed_state)
    expect(engine).to have_received(:parse_input).with("new command", is_nested: true)
    expect(engine).to have_received(:store_parsed_words)
    expect(engine).to have_received(:log_parser_result)
  end

  context "when there is no quoted buffer" do
    let(:quoted_buffer) { nil }

    it "returns ok without changing parser state" do
      expect(registry.call("PARSE")).to eq(:ok)

      expect(engine).not_to have_received(:clear_parsed_state)
      expect(engine).not_to have_received(:parse_input)
    end
  end
end
