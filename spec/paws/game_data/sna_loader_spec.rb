# frozen_string_literal: true

require "spec_helper"
require "paws/game_data/sna_loader"

RSpec.describe PAWS::SNALoader do
  let(:loader) { PAWS::SNALoader.new }
  let(:espia_path) { File.expand_path("../../../games/espia.sna", __dir__) }
  let(:espia_z80_path) { File.expand_path("../../../games/espia.z80", __dir__) }
  let(:espia_sp_path) { File.expand_path("../../../games/espia.sp", __dir__) }

  describe "#load_file" do
    context "with real espia.sna fixture" do
      before { loader.load_file(espia_path) }

      it "correctly identifies it as a 128K SNA snapshot" do
        expect(loader.is_128k?).to be true
      end

      it "allocates 64KB (65536 bytes) of standard Spectrum memory" do
        expect(loader.memory).not_to be_nil
        expect(loader.memory.length).to eq(65536)
      end

      it "populates exactly 8 memory pages" do
        expect(loader.pages.size).to eq(8)
        expect(loader.pages.compact.size).to eq(8)
      end

      it "retains faithful byte values at specific addresses" do
        expect(loader.peek(16384)).to eq(0)
        expect(loader.peek(32768)).to eq(61)
        expect(loader.peek(49152)).to eq(150)
      end
    end

    context "with real espia.z80 fixture" do
      before { loader.load_file(espia_z80_path) }

      it "correctly loads a Z80 snapshot" do
        expect(loader.memory).not_to be_nil
        expect(loader.memory.length).to eq(65536)
      end

      it "retains faithful byte values" do
        expect(loader.peek(16_384)).to eq(0)
        expect(loader.peek(32_768)).to eq(61)
        expect(loader.peek(49_152)).to eq(150)
      end
    end

    context "with real espia.sp fixture" do
      before { loader.load_file(espia_sp_path) }

      it "correctly loads an SP snapshot" do
        expect(loader.memory).not_to be_nil
        expect(loader.memory.length).to eq(49152)
        expect(loader.is_128k?).to be false
      end

      it "handles peek using 48K memory offsets" do
        expect(loader.peek(32768)).to eq(1)
        expect(loader.peek(16383)).to be_nil
        expect(loader.peek(65536)).to be_nil
      end
    end

    it "raises error for unsupported formats" do
      expect { loader.load_file("test.txt") }.to raise_error(/Unsupported format/)
    end

    it "raises error for non-existent files" do
      expect { loader.load_file("non_existent.sna") }.to raise_error(Errno::ENOENT)
    end

    it "raises error for invalid SNA file sizes" do
      allow(File).to receive(:binread).with("invalid.sna").and_return("short_binary")
      expect { loader.load_file("invalid.sna") }.to raise_error(/Invalid SNA file/)
    end

    context "with simulated 48K SNA files" do
      it "handles 48K SNA files of exact size 49179" do
        dummy_data = Array.new(49179, 42).pack("C*")
        allow(File).to receive(:binread).with("dummy_48k.sna").and_return(dummy_data)
        loader.load_file("dummy_48k.sna")
        expect(loader.is_128k?).to be false
        expect(loader.memory.length).to eq(49152)
        expect(loader.memory[0]).to eq(42)
      end
    end

    context "with simulated v2/v3 Z80 files" do
      it "handles Z80 files with an extended header" do
        bytes = Array.new(32 + 55, 0)
        bytes[6] = 0
        bytes[7] = 0
        bytes[30] = 55
        bytes[31] = 0
        bytes[34] = 4
        dummy_z80 = bytes.pack("C*")
        allow(File).to receive(:binread).with("dummy_v2.z80").and_return(dummy_z80)
        loader.load_file("dummy_v2.z80")
        expect(loader.is_128k?).to be true
      end

      it "handles v1 Z80 files whose program counter is non-zero" do
        header = Array.new(30, 0)
        header[6] = 0xee
        header[7] = 0x84
        header[12] = 0x20
        body = [0xED, 0xED, 4, 0x2A, 0x00, 0xED, 0xED, 0x00]
        allow(File).to receive(:binread).with("dummy_v1.z80").and_return((header + body).pack("C*"))

        loader.load_file("dummy_v1.z80")

        expect(loader.is_128k?).to be false
        expect(loader.peek(16_384)).to eq(0x2A)
        expect(loader.peek(16_387)).to eq(0x2A)
      end
    end
  end

  describe "#peek" do
    it "returns nil if no snapshot is loaded" do
      expect(loader.peek(16384)).to be_nil
    end

    context "when snapshot is loaded" do
      before { loader.load_file(espia_path) }

      it "returns nil for addresses out of boundaries" do
        expect(loader.peek(-1)).to be_nil
        expect(loader.peek(65536)).to be_nil
      end
    end
  end

  describe "#peek_word" do
    it "returns nil if no snapshot is loaded" do
      expect(loader.peek_word(16384)).to be_nil
    end

    context "when snapshot is loaded" do
      before { loader.load_file(espia_path) }

      it "correctly interprets a little-endian word in memory" do
        expect(loader.peek_word(32768)).to eq(32829) # 61 | (128 << 8)
      end
    end
  end
end
