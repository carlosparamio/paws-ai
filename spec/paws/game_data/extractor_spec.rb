$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "paws/game_data/sna_loader"
require "paws/game_data/extractor"

FIXTURES_DIR = File.expand_path("../../fixtures", __dir__)

RSpec.describe PAWS::Extractor do
  let(:fixture_path) { File.expand_path("../../../games/espia.sna", __dir__) }
  let(:extractor) { PAWS::Extractor.new }

  describe "#extract" do
    context "with real espia.sna fixture" do
      let(:data) { extractor.extract(fixture_path) }

      it "extracts correct game metadata" do
        expect(data["game"]).to include(
          "version" => "paws",
          "paw_version" => 1,
          "num_locations" => 26,
          "num_objects" => 20,
          "num_processes" => 10,
        )
      end

      it "extracts vocabulary correctly" do
        expect(data["vocabulary"]).to be_an(Array)
        expect(data["vocabulary"]).to include(
          hash_including("word" => "SUR", "type" => "noun"),
          hash_including("word" => "ESTE", "type" => "noun")
        )
      end

      it "extracts objects with attributes" do
        linterna = data["objects"].find { |o| o["name"] =~ /linterna/ }
        expect(linterna).to include(
          "id" => 0,
          "weight" => 1,
          "is_container" => false,
        )
      end

      it "extracts locations and connections" do
        expect(data["locations"].size).to eq(26)
        expect(data["connections"]).not_to be_empty

        # In Espía, location 3 has connections
        loc3_con = data["connections"].find { |c| c[0] == 3 }
        expect(loc3_con).not_to be_nil
        expect(loc3_con[1]).to be_an(Array)
        expect(loc3_con[1]).to include([13, 4]) # West to location 4
      end

      it "extracts messages and processes" do
        expect(data["messages"]).to be_an(Array)
        expect(data["messages"]).not_to be_empty
        expect(data["processes"]).to be_an(Array)
        expect(data["processes"].size).to eq(10)
      end

      it "does not emit graphics placeholders when no real drawstrings are present" do
        expect(data).not_to have_key("pictures")
      end
    end

    context "with things.sna graphics" do
      fixture_path = File.expand_path("../../../games/things.sna", __dir__)
      skip "games/things.sna fixture is not available" unless File.exist?(fixture_path)

      let(:fixture_path) { fixture_path }
      let(:data) { extractor.extract(fixture_path) }

      it "extracts raw picture table metadata and drawstring bytes" do
        expect(data["pictures"]).to include(
          "drawstrings_start" => 0xD254,
          "picture_table" => 0xFF85,
          "location_flags" => 0xFFBB,
          "graphics_end" => 0xFFD4,
        )
        expect(data["pictures"]["summary"]).to include(
          "entry_count" => 25,
          "drawable_count" => 24,
          "raw_byte_count" => 11_569,
          "decoded_command_count" => 3_619,
          "decode_warning_count" => 0,
        )

        first_picture = data["pictures"]["entries"][0]
        expect(first_picture).to include(
          "id" => 0,
          "pointer" => 0xD254,
          "length" => 0x225,
          "location_flag" => 0x87,
          "drawable" => true,
          "paper" => 0,
          "ink" => 7,
        )
        expect(first_picture["raw_bytes"].first(8)).to eq([0x00, 0x08, 0x87, 0x81, 0x66, 0x08, 0x00, 0x6F])
        expect(first_picture["decoded_commands"].first).to include(
          "offset" => 0,
          "name" => "plot",
          "raw_bytes" => [0x00, 0x08, 0x87],
        )
      end

      it "keeps subroutine or empty pictures in the raw table" do
        entries = data["pictures"]["entries"]

        expect(entries.size).to eq(25)
        expect(entries[1]).to include(
          "id" => 1,
          "pointer" => 0xD479,
          "length" => 1,
          "location_flag" => 0x07,
          "drawable" => false,
          "raw_bytes" => [0x07],
        )
      end
    end

    context "with firfurcio.sna PAW v1 graphics" do
      fixture_path = File.expand_path("../../../games/firfurcio.sna", __dir__)
      skip "games/firfurcio.sna fixture is not available" unless File.exist?(fixture_path)

      let(:fixture_path) { fixture_path }
      let(:data) { extractor.extract(fixture_path) }

      it "keeps leading drawstring bytes addressed by the picture table" do
        picture = data.fetch("pictures").fetch("entries").find { |entry| entry.fetch("id") == 1 }

        expect(data.fetch("pictures")).to include(
          "drawstrings_start" => 0xC81C,
          "location_flags" => nil,
        )
        expect(picture).to include(
          "pointer" => 0xC81D,
          "effective_pointer" => 0xC81D,
          "length" => 1492,
        )
        expect(picture.fetch("decode_warnings")).to be_empty
        expect(picture.fetch("raw_bytes").first(6)).to eq([0x19, 0x2B, 0xAF, 0xC1, 0x08, 0x03])
      end
    end

    context "unit testing with mocked memory" do
      let(:loader) { instance_double(PAWS::SNALoader) }
      let(:main_top) { 40000 }
      let(:memory) { Hash.new(0) }

      def set_word(addr, value)
        memory[addr] = value & 0xFF
        memory[addr + 1] = (value >> 8) & 0xFF
      end

      before do
        allow(PAWS::SNALoader).to receive(:new).and_return(loader)
        allow(loader).to receive(:load_file).and_return(loader)

        # Setup memory map
        set_word(PAWS::Extractor::ADDR_MAIN_TOP, main_top)
        (0..5).each do |i|
          memory[main_top + 311 + i * 2] = 16 + i
        end

        # Game info
        memory[main_top + 325] = 1 # num_locations
        memory[main_top + 326] = 1 # num_messages
        memory[main_top + 327] = 1 # num_system_messages
        memory[main_top + 324] = 1 # num_objects
        memory[main_top + 328] = 1 # num_processes
        memory[65527] = 1          # paw_version

        # Addresses
        set_word(PAWS::Extractor::ADDR_OFF_LOC, 41000)
        set_word(PAWS::Extractor::ADDR_OFF_MSG, 42000)
        set_word(PAWS::Extractor::ADDR_OFF_SYS, 43000)
        set_word(PAWS::Extractor::ADDR_OFF_VOC, 44000)
        set_word(PAWS::Extractor::ADDR_OFF_CON, 45000)
        set_word(PAWS::Extractor::ADDR_OFF_PRO, 46000)
        set_word(PAWS::Extractor::ADDR_OFF_OBJ, 47000)
        set_word(PAWS::Extractor::ADDR_OFF_LOBJ, 48000)
        set_word(PAWS::Extractor::ADDR_OFF_WOBJ, 48100)
        set_word(PAWS::Extractor::ADDR_OFF_XOBJ, 48200)

        # Terminators to avoid infinite loops
        memory[0] = 255     # Global terminator
        memory[44000] = 0   # Voc (0 means empty list)
        set_word(45000, 45100) # loc 0 con ptr
        memory[45100] = 255 # Con terminator
        set_word(46000, 46100) # process 0 ptr
        memory[46100] = 0   # Pro terminator (0 byte verb)

        # Abbrev pointer (avoid address 0)
        set_word(main_top + 332, 49000)
        memory[49000] = 255

        allow(loader).to receive(:peek) { |addr| memory[addr] }
        allow(loader).to receive(:peek_word) { |addr| memory[addr] + (memory[addr + 1] << 8) }
      end

      it "extracts XOR-encoded text correctly" do
        # Mock location pointer
        set_word(41000, 50000) # location 0 ptr
        # Mock "HOLA"
        memory[50000] = 72 ^ 0xFF
        memory[50001] = 79 ^ 0xFF
        memory[50002] = 76 ^ 0xFF
        memory[50003] = 65 ^ 0xFF
        memory[50004] = 31 ^ 0xFF

        data = extractor.extract("dummy.sna")
        expect(data["locations"][0]["description"]).to eq("HOLA")
      end

      it "extracts PAWS charset banks without altering readable text" do
        charset_address = 52_000
        udg_address = 53_000
        memory[main_top + 329] = 1
        set_word(main_top + 330, charset_address)
        set_word(PAWS::GameData::CharsetExtractor::SYSVAR_UDG, udg_address)
        memory[charset_address + (65 - 32) * 8] = 0b01111110
        memory[udg_address] = 0b11110000

        set_word(41000, 50000)
        memory[50000] = "A".ord ^ 0xFF
        memory[50001] = 31 ^ 0xFF

        data = extractor.extract("dummy.sna")

        expect(data["locations"][0]["description"]).to eq("A")
        expect(data["charsets"]).to include(
          "count" => 1,
          "address" => charset_address,
          "first_char" => 32,
        )
        expect(data["charsets"]["entries"][0]["glyphs"]["65"].first).to eq(0b01111110)
        expect(data["udgs"]).to include("address" => udg_address, "first_char" => 144)
        expect(data["udgs"]["glyphs"]["144"].first).to eq(0b11110000)
      end

      it "handles control codes in text" do
        set_word(41000, 50000)
        # {ink:red}
        memory[50000] = 16 ^ 0xFF
        memory[50001] = 2 ^ 0xFF
        memory[50002] = 31 ^ 0xFF

        data = extractor.extract("dummy.sna")
        expect(data["locations"][0]["description"]).to eq("{ink:red}")
      end

      it "extracts connections until 255 terminator" do
        set_word(45000, 51000) # connections ptr
        memory[51000] = 0     # North
        memory[51001] = 10    # to Loc 10
        memory[51002] = 255   # terminator

        data = extractor.extract("dummy.sna")
        expect(data["connections"]).to eq([[0, [[0, 10]]]])
      end

      it "extracts vocabulary correctly" do
        memory[44000] = "H".ord ^ 0xFF
        memory[44001] = "O".ord ^ 0xFF
        memory[44002] = "L".ord ^ 0xFF
        memory[44003] = "A".ord ^ 0xFF
        memory[44004] = " ".ord ^ 0xFF
        memory[44005] = 10    # id
        memory[44006] = 2     # type (noun)
        memory[44007] = 0     # terminator

        data = extractor.extract("dummy.sna")
        expect(data["vocabulary"]).to include(
          hash_including("word" => "HOLA", "id" => 10, "type" => "noun")
        )
      end

      it "extracts objects with flags and weights" do
        set_word(47000, 52000) # obj 0 name ptr
        memory[52000] = "L".ord ^ 0xFF
        memory[52001] = 31 ^ 0xFF # end

        memory[48000] = 10    # initial location
        memory[48100] = 5     # noun id
        memory[48101] = 6     # adjective id
        memory[48200] = 0x40 | 5 # container (0x40) + weight (5)

        data = extractor.extract("dummy.sna")
        expect(data["objects"][0]).to include(
          "name" => "L",
          "initial_location" => 10,
          "noun_id" => 5,
          "adjective_id" => 6,
          "weight" => 5,
          "is_container" => true,
        )
      end

      it "extracts processes and condacts" do
        set_word(46000, 53000) # process 0 ptr
        memory[53000] = 10    # verb
        memory[53001] = 20    # noun
        set_word(53002, 54000) # condacts ptr
        memory[53004] = 0     # process end

        memory[54000] = 1     # opcode for AT (condact 1)
        memory[54001] = 5     # param 1
        memory[54002] = 255   # condacts end

        data = extractor.extract("dummy.sna")
        expect(data["processes"][0]["entries"][0]).to include(
          "verb" => 10,
          "noun" => 20,
        )
        expect(data["processes"][0]["entries"][0]["condacts"][0]).to include(
          name: "NOTAT",
          params: [5],
        )
      end

      it "folds unconditional message continuations into previous matching entries" do
        set_word(46000, 53000) # process 0 ptr
        memory[53000] = 10
        memory[53001] = 20
        set_word(53002, 54000)
        memory[53004] = 10
        memory[53005] = 20
        set_word(53006, 54010)
        memory[53008] = 0

        memory[54000] = 77 # MES
        memory[54001] = 32
        memory[54002] = 255
        memory[54010] = 38 # MESSAGE
        memory[54011] = 28
        memory[54012] = 255

        data = extractor.extract("dummy.sna")
        entries = data["processes"][0]["entries"]

        expect(entries.size).to eq(1)
        expect(entries[0]["condacts"].map { |condact| [condact[:name], condact[:params]] }).to eq([
          ["MES", [32]],
          ["MESSAGE", [28]],
        ])
      end

      it "uses custom character mapping" do
        mapping = { "64" => "A", "$" => "B" }
        extractor_custom = PAWS::Extractor.new(mapping: mapping)

        set_word(41000, 50000)
        # Mock "@$" -> "AB"
        memory[50000] = "@".ord ^ 0xFF
        memory[50001] = "$".ord ^ 0xFF
        memory[50002] = 31 ^ 0xFF

        data = extractor_custom.extract("dummy.sna")
        expect(data["locations"][0]["description"]).to eq("AB")
      end

      it "preserves source bytes for non-ASCII mapping fallbacks" do
        mapping = { "$" => "í" }
        extractor_custom = PAWS::Extractor.new(mapping: mapping)

        set_word(41000, 50000)
        memory[50000] = "$".ord ^ 0xFF
        memory[50001] = 31 ^ 0xFF

        data = extractor_custom.extract("dummy.sna")
        expect(data["locations"][0]["description"]).to eq("{glyph:36:í}")
      end
    end
  end
end

RSpec.describe PAWS::SNALoader do
  describe "#load_file" do
    it "loads SNA files" do
      loader = PAWS::SNALoader.new
      expect { loader.load_file("spec/paws/fixtures/nonexistent.sna") }.to raise_error(Errno::ENOENT)
    end

    it "loads Z80 files" do
      loader = PAWS::SNALoader.new
      expect { loader.load_file("spec/paws/fixtures/nonexistent.z80") }.to raise_error(Errno::ENOENT)
    end
  end

  describe "extra extractor coverage cases" do
    let(:loader) { instance_double(PAWS::SNALoader) }
    let(:extractor) { PAWS::Extractor.new }
    let(:main_top) { 40000 }
    let(:memory) { Hash.new { |h, k| k >= 49000 && k < 51000 ? 0x80 : 0 } }

    def set_word(addr, value)
      memory[addr] = value & 0xFF
      memory[addr + 1] = (value >> 8) & 0xFF
    end

    before do
      allow(PAWS::SNALoader).to receive(:new).and_return(loader)
      allow(loader).to receive(:load_file).and_return(loader)
      set_word(PAWS::Extractor::ADDR_MAIN_TOP, main_top)

      # Safe default addresses to avoid infinite loops
      set_word(PAWS::Extractor::ADDR_OFF_LOC, 41000)
      set_word(PAWS::Extractor::ADDR_OFF_MSG, 42000)
      set_word(PAWS::Extractor::ADDR_OFF_SYS, 43000)
      set_word(PAWS::Extractor::ADDR_OFF_VOC, 44000)
      set_word(PAWS::Extractor::ADDR_OFF_CON, 45000)
      set_word(PAWS::Extractor::ADDR_OFF_PRO, 46000)
      set_word(PAWS::Extractor::ADDR_OFF_OBJ, 47000)
      set_word(PAWS::Extractor::ADDR_OFF_LOBJ, 48000)
      set_word(PAWS::Extractor::ADDR_OFF_WOBJ, 48100)
      set_word(PAWS::Extractor::ADDR_OFF_XOBJ, 48200)

      # Terminators
      memory[0] = 255     # Global terminator
      memory[44000] = 0   # Voc
      set_word(45000, 45100)
      memory[45100] = 255
      set_word(46000, 46100)
      memory[46100] = 0

      # Abbrev pointer
      set_word(main_top + 332, 49000)
      memory[49000] = 255

      allow(loader).to receive(:peek) { |addr| memory[addr] }
      allow(loader).to receive(:peek_word) { |addr| memory[addr] + (memory[addr + 1] << 8) }
    end

    it "covers unknown version when signature is missing" do
      # Set signature bytes to 0 to fail signature check
      (0..5).each { |i| memory[main_top + 311 + i * 2] = 0 }
      data = extractor.extract("dummy.sna")
      expect(data["game"]["version"]).to eq("unknown")
    end

    it "covers abbreviation extraction and expansion" do
      # Set valid signature
      (0..5).each { |i| memory[main_top + 311 + i * 2] = 16 + i }
      memory[main_top + 325] = 1 # num_locations
      set_word(PAWS::Extractor::ADDR_OFF_LOC, 41000)
      set_word(41000, 50000)

      # Enable abbreviations (value of off_abbrev is not 255)
      set_word(main_top + 332, 49000)

      # Mock all 16 abbreviations starting at 49000
      # First abbreviation is "OK"
      memory[49000] = "O".ord
      memory[49001] = "K".ord | 0x80
      # Subsequent abbreviations are "A"
      (1..15).each do |i|
        memory[49001 + i] = "A".ord | 0x80
      end

      # Location text uses abbreviation index 0 (byte 164)
      memory[50000] = (164) ^ 0xFF
      memory[50001] = 31 ^ 0xFF

      data = extractor.extract("dummy.sna")
      expect(data["locations"][0]["description"]).to eq("OK")
    end

    it "preserves control codes inside compressed abbreviations" do
      # Set valid signature
      (0..5).each { |i| memory[main_top + 311 + i * 2] = 16 + i }
      memory[main_top + 325] = 1 # num_locations
      set_word(PAWS::Extractor::ADDR_OFF_LOC, 41000)
      set_word(41000, 50000)

      # Enable abbreviations (value of off_abbrev is not 255)
      set_word(main_top + 332, 49000)

      # First abbreviation is INK 5, with the terminator on the parameter byte.
      memory[49000] = 16
      memory[49001] = 5 | 0x80

      # Location text uses abbreviation index 0 (byte 164)
      memory[50000] = 164 ^ 0xFF
      memory[50001] = 31 ^ 0xFF

      data = extractor.extract("dummy.sna")
      expect(data["locations"][0]["description"]).to eq("{ink:cyan}")
    end

    it "covers load_mapping integer keys and resolve_vocab wildcard cases" do
      ext = PAWS::Extractor.new(mapping: { 65 => "X" })
      expect(ext.send(:apply_mapping, "A")).to eq("X")

      ext_with_glyph = PAWS::Extractor.new(mapping: { 65 => "Á" })
      expect(ext_with_glyph.send(:apply_mapping, "A")).to eq("{glyph:65:Á}")

      # Setup resolve_vocab cases
      ext.instance_variable_set(:@verb_vocab, {})
      ext.instance_variable_set(:@noun_vocab, {})
      expect(ext.send(:resolve_vocab, 10, :verb)).to eq("*") # verb < 20 fallback
      expect(ext.send(:resolve_vocab, 25, :verb)).to eq("_") # verb >= 20 fallback
    end

    it "covers unknown condact opcodes" do
      # Set valid signature
      (0..5).each { |i| memory[main_top + 311 + i * 2] = 16 + i }
      memory[main_top + 328] = 1 # num_processes
      set_word(PAWS::Extractor::ADDR_OFF_PRO, 46000)
      set_word(46000, 53000)
      memory[53000] = 10    # verb
      memory[53001] = 20    # noun
      set_word(53002, 54000) # condacts ptr
      memory[53004] = 0     # process end

      memory[54000] = 240   # unknown opcode
      memory[54001] = 255   # condacts end

      data = extractor.extract("dummy.sna")
      expect(data["processes"][0]["entries"][0]["condacts"][0][:name]).to eq("UNKNOWN_240")
    end

    it "covers byte 128 as space in text" do
      (0..5).each { |i| memory[main_top + 311 + i * 2] = 16 + i }
      memory[main_top + 325] = 1 # num_locations
      set_word(PAWS::Extractor::ADDR_OFF_LOC, 41000)
      set_word(41000, 50000)

      # 128 ^ 0xFF is 127
      memory[50000] = 127
      memory[50001] = 31 ^ 0xFF

      data = extractor.extract("dummy.sna")
      expect(data["locations"][0]["description"]).to eq(" ")
    end

    it "loads mapping from a json file path" do
      require "tempfile"
      temp = Tempfile.new(["mapping", ".json"])
      temp.write('{"@": "X"}')
      temp.close

      ext = PAWS::Extractor.new(mapping: temp.path)
      expect(ext.send(:apply_mapping, "@")).to eq("X")
    ensure
      temp.unlink if temp
    end
  end
end
