require "json"

require_relative "abbreviation_extractor"
require_relative "charset_extractor"
require_relative "connection_extractor"
require_relative "condact_metadata"
require_relative "drawstring_decoder"
require_relative "header_extractor"
require_relative "object_extractor"
require_relative "picture_extractor"
require_relative "process_extractor"
require_relative "sna_loader"
require_relative "text_decoder"
require_relative "text_table_extractor"
require_relative "vocabulary_extractor"
require_relative "vocabulary_metadata"
require_relative "../runtime/location_ref"

module PAWS
  # Extracts PAWS game data structures from a loaded SNA memory image.
  # It translates snapshot bytes into the normalized hashes consumed by Engine and fixtures.
  class Extractor
    attr_reader :game_data

    # Fixed addresses for PAW 48K
    ADDR_OFF_LOC = 65_501
    ADDR_OFF_MSG = 65_503
    ADDR_OFF_SYS = 65_505
    ADDR_OFF_CON = 65_507
    ADDR_OFF_VOC = 65_509
    ADDR_OFF_LOBJ = 65_511
    ADDR_OFF_WOBJ = 65_513
    ADDR_OFF_XOBJ = 65_515
    ADDR_OFF_GRAPHICS_START = 65_517
    ADDR_OFF_V1_PICTURE_FLAGS = 65_519
    ADDR_OFF_V2_DRAWSTRINGS = 65_519
    ADDR_OFF_PICTURES = 65_521
    ADDR_OFF_V2_PICTURE_FLAGS = 65_523
    ADDR_OFF_GRAPHICS_END = 65_525
    ADDR_OFF_PRO = 65_497
    ADDR_OFF_OBJ = 65_499
    ADDR_MAIN_TOP = 65_533

    DEFAULT_MAPPING = GameData::TextDecoder::DEFAULT_MAPPING

    def initialize(mapping: nil)
      @sna = nil
      @game_data = {}
      @version = nil
      @paw_version = nil
      @compressed = false
      @main_top = nil
      @off_abbrev = nil
      @char_mapping = load_mapping(mapping)
    end

    def extract(sna_path)
      @sna = SNALoader.new.load_file(sna_path)

      detect_version
      extract_game_info
      extract_defaults
      extract_charsets
      extract_vocabulary
      extract_locations
      extract_messages
      extract_system_messages
      extract_objects
      extract_pictures
      extract_processes
      extract_abbreviations

      @game_data
    end

    private

    def detect_version
      header = header_extractor.detect
      @main_top = header.main_top
      @version = header.version
      @paw_version = header.paw_version
      @compressed = header.compressed
      @off_abbrev = header.off_abbrev
    end

    def extract_game_info
      @game_data["game"] = header_extractor.game_info(header)
    end

    def extract_vocabulary
      off_voc = @sna.peek_word(ADDR_OFF_VOC)
      return unless off_voc

      @game_data["vocabulary"] = vocabulary_extractor.extract(off_voc)
    end

    def extract_messages
      off_msg = @sna.peek_word(ADDR_OFF_MSG)
      num_msg = @game_data.dig("game", "num_messages") || 0
      return unless off_msg && num_msg > 0

      @game_data["messages"] = text_table_extractor.extract_messages(off_msg, num_msg)
    end

    def extract_system_messages
      off_sys = @sna.peek_word(ADDR_OFF_SYS)
      num_sys = @game_data.dig("game", "num_system_messages") || 0
      return unless off_sys && num_sys > 0

      @game_data["system_messages"] = text_table_extractor.extract_messages(off_sys, num_sys)
    end

    def extract_locations
      off_loc = @sna.peek_word(ADDR_OFF_LOC)
      num_loc = @game_data.dig("game", "num_locations") || 0
      return unless off_loc && num_loc > 0

      @game_data["locations"] = text_table_extractor.extract_locations(off_loc, num_loc)

      # Extract connections for movement
      extract_connections
    end

    def extract_connections
      off_con = @sna.peek_word(ADDR_OFF_CON)
      num_loc = @game_data.dig("game", "num_locations") || 0
      return unless off_con && num_loc > 0

      @game_data["connections"] = connection_extractor.extract(off_con, num_loc)
    end

    def extract_objects
      off_obj = @sna.peek_word(ADDR_OFF_OBJ)
      off_lobj = @sna.peek_word(ADDR_OFF_LOBJ)
      off_wobj = @sna.peek_word(ADDR_OFF_WOBJ)
      off_xobj = @sna.peek_word(ADDR_OFF_XOBJ)
      num_obj = @game_data.dig("game", "num_objects") || 0
      return unless num_obj > 0

      @game_data["objects"] = object_extractor.extract(
        count: num_obj,
        name_offset: off_obj,
        location_offset: off_lobj,
        word_offset: off_wobj,
        extra_offset: off_xobj,
      )
    end

    def extract_pictures
      num_loc = @game_data.dig("game", "num_locations") || 0
      offsets = picture_offsets
      location_flags = offsets[:location_flags] && @sna.peek_word(offsets.fetch(:location_flags))
      pictures = picture_extractor.extract(
        drawstrings_start: drawstrings_start(offsets, location_flags, num_loc),
        picture_table: @sna.peek_word(offsets.fetch(:picture_table)),
        location_flags: location_flags,
        graphics_end: @sna.peek_word(ADDR_OFF_GRAPHICS_END),
        location_count: num_loc,
        flags_before_drawstrings: offsets.fetch(:flags_before_drawstrings, false),
      )

      @game_data["pictures"] = pictures if pictures
    end

    def drawstrings_start(offsets, location_flags, location_count)
      return @sna.peek_word(offsets.fetch(:drawstrings)) if offsets[:drawstrings]

      location_flags + location_count
    end

    def picture_offsets
      if @paw_version.to_i >= 2
        {
          drawstrings: ADDR_OFF_V2_DRAWSTRINGS,
          picture_table: ADDR_OFF_PICTURES,
          location_flags: ADDR_OFF_V2_PICTURE_FLAGS,
        }
      else
        {
          drawstrings: ADDR_OFF_V1_PICTURE_FLAGS,
          picture_table: ADDR_OFF_PICTURES,
        }
      end
    end

    def extract_defaults
      defaults = header_extractor.defaults(header)
      @game_data["defaults"] = defaults if defaults
    end

    def extract_charsets
      charsets = charset_extractor.extract(header_extractor.charset_table(header))
      @game_data["charsets"] = charsets if charsets

      udgs = charset_extractor.extract_udgs
      @game_data["udgs"] = udgs if udgs

      shade_patterns = charset_extractor.extract_shade_patterns(@main_top)
      @game_data["shade_patterns"] = shade_patterns if shade_patterns
    end

    def extract_processes
      off_pro = @sna.peek_word(ADDR_OFF_PRO)
      num_pro = @game_data.dig("game", "num_processes") || 0
      return unless off_pro && num_pro > 0

      extractor = process_extractor
      @game_data["processes"] = extractor.extract(off_pro, num_pro)
      @verb_vocab = extractor.verb_vocab
      @noun_vocab = extractor.noun_vocab
    end

    def extract_abbreviations
      return unless @compressed && @off_abbrev

      @game_data["abbreviations"] = abbreviation_extractor.extract
    end

    def resolve_vocab(value, type)
      process_extractor.resolve_vocab(value, type)
    end

    def extract_condacts(ptr)
      process_extractor.extract_condacts(ptr)
    end

    def read_xor_string(addr, length)
      text_decoder.read_xor_string(addr, length)
    end

    def expand_paws_text(addr)
      text_decoder.expand_paws_text(addr)
    end

    def expand_abbreviation(index)
      text_decoder.expand_abbreviation(index)
    end

    private

    def apply_mapping(text)
      text_decoder.apply_mapping(text)
    end

    def load_mapping(mapping_source)
      GameData::TextDecoder.load_mapping(mapping_source)
    end

    def text_decoder
      GameData::TextDecoder.new(
        sna: @sna,
        char_mapping: @char_mapping,
        compressed: @compressed,
        off_abbrev: @off_abbrev,
      )
    end

    def header
      GameData::HeaderExtractor::Header.new(
        main_top: @main_top,
        version: @version,
        paw_version: @paw_version,
        compressed: @compressed,
        off_abbrev: @off_abbrev,
      )
    end

    def header_extractor
      GameData::HeaderExtractor.new(sna: @sna)
    end

    def abbreviation_extractor
      GameData::AbbreviationExtractor.new(text_decoder: text_decoder)
    end

    def vocabulary_extractor
      GameData::VocabularyExtractor.new(sna: @sna, text_decoder: text_decoder)
    end

    def text_table_extractor
      GameData::TextTableExtractor.new(sna: @sna, text_decoder: text_decoder)
    end

    def connection_extractor
      GameData::ConnectionExtractor.new(sna: @sna)
    end

    def object_extractor
      GameData::ObjectExtractor.new(sna: @sna, text_decoder: text_decoder)
    end

    def picture_extractor
      GameData::PictureExtractor.new(sna: @sna)
    end

    def charset_extractor
      GameData::CharsetExtractor.new(sna: @sna)
    end

    def process_extractor
      GameData::ProcessExtractor.new(
        sna: @sna,
        vocabulary: @game_data["vocabulary"],
        verb_vocab: @verb_vocab,
        noun_vocab: @noun_vocab,
      )
    end
  end
end
