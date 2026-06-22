# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::Debug::RemoteRegistry do
  RemoteRegistryController = Struct.new(:id, :paused) do
    def paused?
      paused
    end

    def summary
      { "session_id" => id, "status" => paused? ? "paused" : "running" }
    end
  end

  it "registers, finds, lists, and unregisters controllers" do
    registry = described_class.new
    controller = RemoteRegistryController.new("session-1", false)

    expect(registry.register(controller)).to eq(controller)
    expect(registry.find("session-1")).to eq(controller)
    expect(registry.sessions).to eq([{ "session_id" => "session-1", "status" => "running" }])

    registry.unregister("session-1")

    expect(registry.find("session-1")).to be_nil
    expect(registry.sessions).to eq([])
  end

  it "prefers a paused controller as current" do
    registry = described_class.new
    running = RemoteRegistryController.new("running", false)
    paused = RemoteRegistryController.new("paused", true)

    registry.register(running)
    registry.register(paused)

    expect(registry.current).to eq(paused)
  end
end
