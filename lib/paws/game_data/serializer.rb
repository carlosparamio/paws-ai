require "json"

module PAWS
  module GameData
    # Serializes extracted game data to JSON for fixtures, debugging, and persisted game definitions.
    # It does not normalize schema; callers should pass already-structured game_data.
    class Serializer
      def self.to_json(game_data, pretty: true)
        if pretty
          JSON.pretty_generate(game_data)
        else
          JSON.generate(game_data)
        end
      end

      def self.from_json(json_string)
        JSON.parse(json_string, symbolize_names: true)
      end

      def self.save(game_data, path, pretty: true)
        File.write(path, to_json(game_data, pretty: pretty))
      end

      def self.load(path)
        from_json(File.read(path))
      end
    end
  end
end
