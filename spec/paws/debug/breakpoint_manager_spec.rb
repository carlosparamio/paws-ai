# frozen_string_literal: true

require "spec_helper"
require "paws/debug/breakpoint_manager"
require "tempfile"

RSpec.describe PAWS::BreakpointManager do
  subject(:manager) { PAWS::BreakpointManager.new }

  describe "#parse_line" do
    it "parses execution breakpoints" do
      manager.parse_line("P1")
      expect(manager.breakpoints[:execution]).to include({ process: 1, block: :any, condact: :any })

      manager.parse_line("P1B5")
      expect(manager.breakpoints[:execution]).to include({ process: 1, block: 5, condact: :any })

      manager.parse_line("P2B*")
      expect(manager.breakpoints[:execution]).to include({ process: 2, block: :any, condact: :any })

      manager.parse_line("P3B*C*")
      expect(manager.breakpoints[:execution]).to include({ process: 3, block: :any, condact: :any })
    end

    it "parses location breakpoints" do
      manager.parse_line("L10")
      expect(manager.breakpoints[:locations]).to include(10)
    end

    it "parses flag breakpoints" do
      manager.parse_line("F8=7")
      expect(manager.breakpoints[:flags]).to include({ flag: 8, op: "=", value: 7 })

      manager.parse_line("F10>5")
      expect(manager.breakpoints[:flags]).to include({ flag: 10, op: ">", value: 5 })

      manager.parse_line("F12<100")
      expect(manager.breakpoints[:flags]).to include({ flag: 12, op: "<", value: 100 })

      manager.parse_line("F6")
      expect(manager.breakpoints[:flags]).to include({ flag: 6, op: "!", value: nil })
    end

    it "parses object breakpoints" do
      manager.parse_line("O1=HERE")
      expect(manager.breakpoints[:objects]).to include({ object: 1, location: PAWS::LocationRef.parse("HERE") })

      manager.parse_line("O5=254")
      expect(manager.breakpoints[:objects]).to include({ object: 5, location: PAWS::LocationRef.parse("254") })
    end
  end

  describe "#check_execution?" do
    before do
      manager.parse_line("P1B*")
      manager.parse_line("P2B3C*")
      manager.parse_line("P4B5C6")
    end

    it "matches exact process/block/condact" do
      expect(manager.check_execution?(4, 5, 6)).to be true
      expect(manager.check_execution?(4, 5, 7)).to be false
    end

    it "matches any block/condact with wildcards" do
      expect(manager.check_execution?(1, 10, 20)).to be true
      expect(manager.check_execution?(2, 3, 50)).to be true
      expect(manager.check_execution?(2, 4, 50)).to be false
    end
  end

  describe "#check_flag?" do
    it "matches equality" do
      manager.parse_line("F8=10")
      expect(manager.check_flag?(8, 0, 10)).to be true
      expect(manager.check_flag?(8, 0, 11)).to be false
    end

    it "matches inequality (change)" do
      manager.parse_line("F8")
      expect(manager.check_flag?(8, 10, 11)).to be true
      expect(manager.check_flag?(8, 10, 10)).to be false
    end

    it "matches greater than" do
      manager.parse_line("F8>10")
      expect(manager.check_flag?(8, 0, 11)).to be true
      expect(manager.check_flag?(8, 0, 10)).to be false
    end

    it "matches less than" do
      manager.parse_line("F8<10")
      expect(manager.check_flag?(8, 0, 9)).to be true
      expect(manager.check_flag?(8, 0, 10)).to be false
    end

    it "returns false for unsupported operations" do
      manager.breakpoints[:flags] << { flag: 8, op: "?", value: 10 }
      expect(manager.check_flag?(8, 0, 10)).to be false
    end
  end

  describe "#check_location?" do
    it "matches location" do
      manager.parse_line("L10")
      expect(manager.check_location?(10)).to be true
      expect(manager.check_location?(11)).to be false
    end
  end

  describe "#check_object?" do
    it "matches object location" do
      manager.parse_line("O1=HERE")
      expect(manager.check_object?(1, 0, "HERE")).to be true
      expect(manager.check_object?(1, 0, "254")).to be false
    end

    it "is case-insensitive for location names" do
      manager.parse_line("O1=here")
      expect(manager.check_object?(1, 0, "HERE")).to be true
    end

    it "matches HERE against the current numeric player location" do
      manager.parse_line("O1=HERE")
      expect(manager.check_object?(1, 0, 5, current_location: 5)).to be true
      expect(manager.check_object?(1, 0, 6, current_location: 5)).to be false
    end
  end

  describe "#remove_by_index" do
    before do
      manager.parse_line("P1")   # index 0
      manager.parse_line("F8=7") # index 1
      manager.parse_line("L10")  # index 2
      manager.parse_line("O1=HERE") # index 3
    end

    it "removes execution breakpoints" do
      expect(manager.remove_by_index(0)).to be true
      expect(manager.breakpoints[:execution]).to be_empty
    end

    it "removes flag breakpoints" do
      expect(manager.remove_by_index(1)).to be true
      expect(manager.breakpoints[:flags]).to be_empty
    end

    it "removes location breakpoints" do
      expect(manager.remove_by_index(2)).to be true
      expect(manager.breakpoints[:locations]).to be_empty
    end

    it "removes object breakpoints" do
      expect(manager.remove_by_index(3)).to be true
      expect(manager.breakpoints[:objects]).to be_empty
    end

    it "returns false for invalid index" do
      expect(manager.remove_by_index(10)).to be false
    end
  end

  describe "#load_file" do
    it "loads breakpoints from a file" do
      Tempfile.create("breakpoints") do |f|
        f.puts "P1 # Process 1"
        f.puts "L10"
        f.puts ""
        f.puts "F8=7"
        f.rewind

        manager.load_file(f.path)
        expect(manager.breakpoints[:execution]).not_to be_empty
        expect(manager.breakpoints[:locations]).not_to be_empty
        expect(manager.breakpoints[:flags]).not_to be_empty
      end
    end
  end
end
