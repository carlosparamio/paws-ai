# frozen_string_literal: true

require "paws_helper"

RSpec.describe "El Espia regressions" do
  def run_description(engine)
    catch(:desc_jump) { engine.send(:description_phase) }
  end

  it "keeps Don visible when refreshing the current location with M" do
    game_data = JSON.parse(File.read("games/espia.json"))
    ui = PAWS::TestSupport::HeadlessUI.new
    engine = PAWS::Engine.new(game_data, ui, skip_clear_screen: true)
    engine.instance_variable_set(:@running, true)

    run_description(engine)
    run_description(engine) if engine.describe_flag

    expect(ui.output_lines.grep(/Don está aquí, sentado/)).not_to be_empty

    ui.output_lines.clear
    engine.send(:parse_input, "M")
    engine.send(:store_parsed_words)
    catch(:desc_jump) { engine.send(:response_phase) }
    run_description(engine) if engine.describe_flag

    expect(ui.output_lines.grep(/Don está aquí, sentado/)).not_to be_empty
  end

  it "continues a PSI command process after PARSE reparses quoted speech" do
    game_data = JSON.parse(File.read("games/espia.json"))
    ui = PAWS::TestSupport::HeadlessUI.new
    engine = PAWS::Engine.new(game_data, ui, skip_clear_screen: true)
    engine.instance_variable_set(:@running, true)

    run_description(engine)
    run_description(engine) if engine.describe_flag
    ui.output_lines.clear

    engine.send(:parse_input, 'decir don "sigueme"')
    engine.send(:store_parsed_words)
    catch(:desc_jump) { engine.send(:response_phase) }

    expect(ui.output_lines).to include("Don se levanta.")
    expect(engine.state.get_flag(66)).to eq(255)
  end
end
