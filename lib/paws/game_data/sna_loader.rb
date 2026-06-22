module PAWS
  # Loads ZX Spectrum SNA snapshots and exposes byte/word reads over their memory image.
  # Higher-level extraction code should ask this class for raw memory, not parse file bytes itself.
  class SNALoader
    attr_reader :memory, :pages

    def initialize
      @memory = nil
      @pages = []
      @is_128k = false
      @snappage = 0
    end

    def load_file(path)
      ext = File.extname(path).downcase
      case ext
      when ".sna" then load_sna(path)
      when ".z80" then load_z80(path)
      when ".sp" then load_sp(path)
      else raise "Unsupported format: #{ext}"
      end
      self
    end

    def peek(addr)
      return nil if @memory.nil?
      return nil if addr < 0 || addr > 65_535

      # If memory is 65536 bytes, use direct address.
      # If it's 49152 bytes, it starts at 16384.
      if @memory.length == 65_536
        @memory[addr]
      else
        idx = addr - 16_384
        return nil if idx < 0 || idx >= @memory.length
        @memory[idx]
      end
    end

    def peek_word(addr)
      lo = peek(addr)
      hi = peek(addr + 1)
      return nil if lo.nil? || hi.nil?

      lo | (hi << 8)
    end

    def is_128k?
      @is_128k
    end

    private

    def load_sna(path)
      data = File.binread(path)
      if [49_179, 49_363].include?(data.length)
        @is_128k = false
        @memory = data[27, 49_152].bytes
      elsif data.length >= 131_103
        load_sna_128k(data)
      else
        raise "Invalid SNA file: #{path}"
      end
    end

    def load_sna_128k(data)
      @is_128k = true
      @snappage = data[49_181].ord & 0x07

      # Memory in SNA 128K:
      # data[27, 16384] -> Bank 5 (at 16384)
      # data[27+16384, 16384] -> Bank 2 (at 32768)
      # data[27+32768, 16384] -> Bank n (at 49152)

      @memory = Array.new(65_536, 0)
      @memory[16_384, 49_152] = data[27, 49_152].bytes

      @pages = Array.new(8)
      @pages[5] = @memory[16_384, 16_384]
      @pages[2] = @memory[32_768, 16_384]
      @pages[@snappage] = @memory[49_152, 16_384]

      # Remaining banks are in data[49183..] in numerical order
      current_pos = 49_183
      (0..7).each do |i|
        next if [5, 2, @snappage].include?(i)

        @pages[i] = data[current_pos, 16_384].bytes
        current_pos += 16_384
      end
    end

    def load_z80(path)
      data = File.binread(path).bytes
      pc = data[6] | (data[7] << 8)

      if pc.zero?
        load_z80_extended(data)
      else
        load_z80_v1(data)
      end
    end

    def load_z80_v1(data)
      @is_128k = false
      output = Array.new(65_536, 0)
      body = data[30..] || []
      memory = (data[12] & 0x20) != 0 ? decode_z80_rle(body, 49_152) : body.first(49_152)
      output[16_384, memory.length] = memory
      @memory = output
    end

    def load_z80_extended(data)
      extra_header_size = data[30] | (data[31] << 8)
      blocks_start = 32 + extra_header_size
      hardware_mode = data[34] || 0
      last_7ffd = data[35] || 0
      @is_128k = z80_128k_hardware?(hardware_mode)

      output = Array.new(65_536, 0)
      @pages = Array.new(8) if @is_128k

      ptr = blocks_start
      while ptr + 2 < data.length
        compressed_length = data[ptr] | (data[ptr + 1] << 8)
        page = data[ptr + 2]
        ptr += 3

        block = if compressed_length == 0xffff
            data[ptr, 16_384] || []
          else
            decode_z80_rle(data[ptr, compressed_length] || [], 16_384)
          end

        map_z80_page(output, page, block, last_7ffd)
        ptr += compressed_length == 0xffff ? 16_384 : compressed_length
      end

      @memory = output
    end

    def z80_128k_hardware?(hardware_mode)
      [3, 4, 5, 6, 12].include?(hardware_mode)
    end

    def map_z80_page(output, page, block, last_7ffd)
      if @is_128k && page.between?(3, 10)
        bank = page - 3
        @pages[bank] = block
        address = case bank
          when 5 then 16_384
          when 2 then 32_768
          when last_7ffd & 0x07 then 49_152
          end
      else
        address = { 8 => 16_384, 4 => 32_768, 5 => 49_152 }[page]
      end

      output[address, block.length] = block if address
    end

    def decode_z80_rle(bytes, max_length)
      output = []
      ptr = 0
      while output.length < max_length && ptr < bytes.length
        if bytes[ptr] == 0x00 && bytes[ptr + 1] == 0xED && bytes[ptr + 2] == 0xED && bytes[ptr + 3] == 0x00
          break
        elsif bytes[ptr] == 0xED && bytes[ptr + 1] == 0xED
          ptr += 2
          count = bytes[ptr]
          ptr += 1
          value = bytes[ptr]
          ptr += 1
          count.times { output << value if output.length < max_length }
        else
          output << bytes[ptr]
          ptr += 1
        end
      end
      output
    end

    def load_sp(path)
      data = File.binread(path)
      @is_128k = false
      @memory = data[0, 49_152].bytes
    end
  end
end
