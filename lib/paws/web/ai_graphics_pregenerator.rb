# frozen_string_literal: true

require "json"
require_relative "../utils/text_markup"
require_relative "ai_graphics_enhancer"
require_relative "graphics_presenter"

module PAWS
  module Web
    # Batch pre-generation for AI-enhanced location artwork.
    class AIGraphicsPregenerator
      CACHE_ROOT = File.expand_path("../../../cache", __dir__)
      Target = Struct.new(:picture_id, :location_id, :location_ids, :description, :cache_path, :inference, keyword_init: true)

      def initialize(game_path:, mapping: nil, style: AIGraphicsEnhancer::DEFAULT_STYLE, cache_root: CACHE_ROOT, force: false, logger: nil)
        @game_path = game_path
        @mapping = mapping
        @style = style
        @cache_root = cache_root
        @force = force
        @logger = logger || ->(message) { warn(message) }
        @game_data = load_game_data(game_path)
        @graphics = GraphicsPresenter.new(@game_data)
        @enhancer = AIGraphicsEnhancer.new(
          game_slug: File.basename(@game_path, File.extname(@game_path)),
          cache_root: @cache_root,
          style: @style,
          logger: @logger,
        )
      end

      attr_reader :game_data, :graphics, :enhancer

      def targets
        graphics.picture_ids.filter_map do |picture_id|
          frame = graphics.frame_for_picture(picture_id)
          next if frame.fetch("pixels_set", 0).to_i.zero?

          Target.new(
            picture_id: picture_id,
            location_id: location_for_picture(picture_id),
            location_ids: locations_for_picture(picture_id),
            description: description_for_picture(picture_id),
            cache_path: enhancer.cached_path(picture_id),
            inference: inference_for_picture(picture_id),
          )
        rescue KeyError
          nil
        end
      end

      def run
        summary = { total: 0, generated: 0, skipped: 0, failed: 0, errors: [] }
        targets.each do |target|
          summary[:total] += 1
          log_target(target)
          frame = graphics.frame_for_picture(target.picture_id)
          result = enhancer.generate_frame(frame, description: target.description, force: @force)
          if result["skipped"]
            summary[:skipped] += 1
            log("skip pic#{target.picture_id} cached=#{target.cache_path}")
          else
            summary[:generated] += 1
            log("done pic#{target.picture_id} cache=#{target.cache_path}")
          end
        rescue StandardError => e
          summary[:failed] += 1
          summary[:errors] << { picture_id: target&.picture_id, message: e.message }
          log("error pic#{target&.picture_id || "?"} #{e.class}: #{e.message}")
        end
        summary
      end

      private

      def load_game_data(path)
        ext = File.extname(path).downcase
        case ext
        when ".json"
          JSON.parse(File.read(path))
        when ".sna", ".z80", ".sp"
          PAWS::Extractor.new(mapping: @mapping).extract(path)
        else
          raise ArgumentError, "Unsupported file format: #{ext}"
        end
      end

      def location_for_picture(picture_id)
        locations_for_picture(picture_id).first
      end

      def description_for_picture(picture_id)
        locations = locations_for_picture(picture_id).filter_map { |location_id| locations_by_id[location_id] }
        return "Picture #{picture_id}; no matching location description was extracted." if locations.empty?
        return TextMarkup.strip_tags(locations.first.fetch("description", "").to_s) if locations.one?

        locations.map do |location|
          "Location #{location.fetch("id")}: #{TextMarkup.strip_tags(location.fetch("description", "").to_s)}"
        end.join("\n")
      end

      def locations_by_id
        @locations_by_id ||= game_data.fetch("locations", []).each_with_object({}) do |location, memo|
          memo[value_for(location, "id").to_i] = location
        end
      end

      def locations_for_picture(picture_id)
        explicit = picture_location_index[picture_id.to_i]
        return explicit if explicit&.any?

        locations_by_id.key?(picture_id.to_i) ? [picture_id.to_i] : []
      end

      def inference_for_picture(picture_id)
        return "condacts" if picture_location_index[picture_id.to_i]&.any?
        return "picture_id == location_id" if locations_by_id.key?(picture_id.to_i)

        "none"
      end

      def picture_location_index
        @picture_location_index ||= begin
          index = Hash.new { |hash, key| hash[key] = [] }
          process_entries.each do |entry|
            current_locations = []
            condacts_for(entry).each do |condact|
              name = condact_name(condact)
              params = condact_params(condact)

              case name
              when "AT"
                current_locations |= [params.fetch(0).to_i]
              when "GOTO"
                current_locations = [params.fetch(0).to_i]
              when "DESC"
                current_locations = []
              when "PICTURE"
                picture_id = params.fetch(0).to_i
                current_locations.each do |location_id|
                  index[picture_id] << location_id unless index[picture_id].include?(location_id)
                end
              end
            end
          end
          index
        end
      end

      def process_entries
        raw_processes = game_data.fetch("processes", [])
        processes = raw_processes.is_a?(Hash) ? raw_processes.values : raw_processes
        processes.flat_map do |process|
          entries = value_for(process, "entries") || []
          entries.is_a?(Hash) ? entries.values : entries
        end
      end

      def condacts_for(entry)
        value_for(entry, "condacts") || []
      end

      def condact_name(condact)
        value_for(condact, "name").to_s
      end

      def condact_params(condact)
        value_for(condact, "params") || []
      end

      def value_for(hash, key)
        hash.fetch(key) { hash.fetch(key.to_sym) { nil } }
      end

      def log_target(target)
        location_text = target.location_ids.any? ? "loc#{target.location_ids.join(",loc")}" : "no-loc"
        log("generate pic#{target.picture_id} #{location_text} inference=#{target.inference} style=#{@style} cache=#{target.cache_path}")
      end

      def log(message)
        @logger.call("[ai-graphics:pregen] #{message}")
      end
    end
  end
end
