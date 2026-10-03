# frozen_string_literal: true

require "paws_helper"
require "json"

RSpec.describe "PAWS Classic Parser Z80 Differential Suite" do
  let(:game_data) { JSON.parse(File.read("games/espia.json")) }
  let(:repository) { PAWS::GameData::Repository.new(game_data) }
  let(:ui) { PAWS::TestSupport::HeadlessUI.new }
  let(:engine) { PAWS::Engine.new(game_data, ui, skip_clear_screen: true) }
  let(:input_phase) { engine.instance_variable_get(:@input_phase) }

  def parse_line(line)
    input_phase.send(:reset_line_verb)
    phrases = input_phase.send(:split_phrases, line)
    phrases.map do |phrase|
      engine.send(:parse_input, phrase)
      engine.send(:store_parsed_words)
      {
        verb: engine.state.get_flag(33) == 255 ? nil : engine.state.get_flag(33),
        noun1: engine.state.get_flag(34) == 255 ? nil : engine.state.get_flag(34),
        noun2: engine.state.get_flag(44) == 255 ? nil : engine.state.get_flag(44),
        prep: engine.state.get_flag(43) == 255 ? nil : engine.state.get_flag(43),
      }
    end
  end

  describe "16 Z80 Battery Cases" do
    it "1. NORTE: direction noun promoted to verb and retained in noun1" do
      clauses = parse_line("NORTE")
      expect(clauses.size).to eq(1)
      expect(clauses[0][:verb]).to eq(13)
      expect(clauses[0][:noun1]).to eq(13)
    end

    it "2. PERRO: standard intransitive verb" do
      clauses = parse_line("PERRO")
      expect(clauses.size).to eq(1)
      expect(clauses[0][:verb]).to eq(25)
      expect(clauses[0][:noun1]).to be_nil
    end

    it "3. COGE NAVAJA: verb + noun" do
      clauses = parse_line("COGE NAVAJA")
      expect(clauses.size).to eq(1)
      expect(clauses[0][:verb]).to eq(20)
      expect(clauses[0][:noun1]).to eq(67)
    end

    it "4. NORTE PERRO: noun + verb routes correctly" do
      clauses = parse_line("NORTE PERRO")
      expect(clauses.size).to eq(1)
      expect(clauses[0][:verb]).to eq(25)
      expect(clauses[0][:noun1]).to eq(13)
    end

    it "5. PERRO BALAS: verb + noun" do
      clauses = parse_line("PERRO BALAS")
      expect(clauses.size).to eq(1)
      expect(clauses[0][:verb]).to eq(25)
      expect(clauses[0][:noun1]).to eq(50)
    end

    it "6. PERRO Y BALAS: two clauses with verb retention" do
      clauses = parse_line("PERRO Y BALAS")
      expect(clauses.size).to eq(2)
      expect(clauses[0]).to eq({ verb: 25, noun1: nil, noun2: nil, prep: nil })
      expect(clauses[1]).to eq({ verb: 25, noun1: 50, noun2: nil, prep: nil })
    end

    it "7. COGE NAVAJA Y BALAS: multi-clause with verb retention across conjunction" do
      clauses = parse_line("COGE NAVAJA Y BALAS")
      expect(clauses.size).to eq(2)
      expect(clauses[0]).to eq({ verb: 20, noun1: 67, noun2: nil, prep: nil })
      expect(clauses[1]).to eq({ verb: 20, noun1: 50, noun2: nil, prep: nil })
    end

    it "7b. COGE NAVAJA, BALAS: multi-clause with verb retention across comma" do
      clauses = parse_line("COGE NAVAJA, BALAS")
      expect(clauses.size).to eq(2)
      expect(clauses[0]).to eq({ verb: 20, noun1: 67, noun2: nil, prep: nil })
      expect(clauses[1]).to eq({ verb: 20, noun1: 50, noun2: nil, prep: nil })
    end

    it "7c. COGE NAVAJA LUEGO BALAS: multi-clause with verb retention across connector LUEGO" do
      clauses = parse_line("COGE NAVAJA LUEGO BALAS")
      expect(clauses.size).to eq(2)
      expect(clauses[0]).to eq({ verb: 20, noun1: 67, noun2: nil, prep: nil })
      expect(clauses[1]).to eq({ verb: 20, noun1: 50, noun2: nil, prep: nil })
    end

    it "8. Y: standalone connector is unparseable" do
      clauses = parse_line("Y")
      expect(clauses.all? { |c| c[:verb].nil? && c[:noun1].nil? }).to be true
    end

    it "9. ZORRO: unknown word is unparseable" do
      clauses = parse_line("ZORRO")
      expect(clauses.all? { |c| c[:verb].nil? && c[:noun1].nil? }).to be true
    end

    it "10. PERRO ZORRO: known verb followed by unknown word" do
      clauses = parse_line("PERRO ZORRO")
      expect(clauses.size).to eq(1)
      expect(clauses[0][:verb]).to eq(25)
      expect(clauses[0][:noun1]).to be_nil
    end

    it "11. COGE NAVAJA CON LLAVE: verb with primary and secondary noun" do
      clauses = parse_line("COGE NAVAJA CON LLAVE")
      expect(clauses.size).to eq(1)
      expect(clauses[0][:verb]).to eq(20)
      expect(clauses[0][:noun1]).to eq(67)
      expect(clauses[0][:noun2]).to eq(65)
    end

    it "12. TOMA NAVAJA CON LLAVE: unknown verb with two nouns" do
      clauses = parse_line("TOMA NAVAJA CON LLAVE")
      expect(clauses.size).to eq(1)
      expect(clauses[0][:verb]).to be_nil
      expect(clauses[0][:noun1]).to eq(67)
      expect(clauses[0][:noun2]).to eq(65)
    end

    it "13. USA CASA: disambiguates homograph verb 81 and noun 81" do
      clauses = parse_line("USA CASA")
      expect(clauses.size).to eq(1)
      expect(clauses[0][:verb]).to eq(81)
      expect(clauses[0][:noun1]).to eq(81)
    end

    it "14. SUBIR: 5-letter movement verb" do
      clauses = parse_line("SUBIR")
      expect(clauses.size).to eq(1)
      expect(clauses[0][:verb]).to eq(9)
      expect(clauses[0][:noun1]).to be_nil
    end

    it "15. SUBE: 4-letter synonym of movement verb" do
      clauses = parse_line("SUBE")
      expect(clauses.size).to eq(1)
      expect(clauses[0][:verb]).to eq(9)
      expect(clauses[0][:noun1]).to be_nil
    end
  end

  describe "Spanish Pronominal Enclitics (-lo, -la, -los, -las)" do
    it "resolves COJELO to verb COGER and noun of referred object" do
      engine.state.set_flag(PAWS::GameState::FLAG_REFERRED_OBJECT, 67) # NAVAJA
      clauses = parse_line("COJELO")
      expect(clauses.size).to eq(1)
      expect(clauses[0][:verb]).to eq(20)
      expect(clauses[0][:noun1]).to eq(67)
    end

    it "resolves COJELAS to verb COGER and noun of referred object" do
      engine.state.set_flag(PAWS::GameState::FLAG_REFERRED_OBJECT, 50) # BALAS
      clauses = parse_line("COJELAS")
      expect(clauses.size).to eq(1)
      expect(clauses[0][:verb]).to eq(20)
      expect(clauses[0][:noun1]).to eq(50)
    end
  end
end
