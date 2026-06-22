# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::Debug::RemoteController do
  class RemoteControllerInterfaceDouble
    attr_reader :autoplay_commands

    def initialize
      @buffer = +""
    end

    def output_text(text = "", newline: true, **)
      @buffer << text.to_s
      @buffer << "\n" if newline
    end

    def output_debug(message, _level = 1)
      output_text(message)
    end

    def install_autoplay_commands(commands)
      @autoplay_commands = commands
    end

    def fmt_p(value)
      format("P%03d", value)
    end

    def fmt_b(value)
      format("B%03d", value)
    end

    def fmt_c(value)
      format("C%03d", value)
    end
  end

  RemoteControllerStateDouble = Struct.new(:location, :turns)
  RemoteControllerRunnerDouble = Struct.new(:process_stack, :entry_index_stack, :condact_index_stack)

  class RemoteControllerBreakpointManagerDouble
    def breakpoints
      ["P001B002"]
    end
  end

  class RemoteControllerDebuggerDouble
    def initialize(engine)
      @engine = engine
      @interface = nil
    end

    def with_interface(interface)
      previous = @interface
      @interface = interface
      yield
    ensure
      @interface = previous
    end

    def handle_repl_input(command, p:, b:, c:)
      @interface.output_text("handled #{command} at #{p}/#{b}/#{c}")

      case command
      when "s", "step"
        @engine.stepping = true
        false
      when "", "c", "continue"
        false
      when "x", "exit"
        @engine.abort_execution = true
        false
      else
        true
      end
    end

    def dump_current_process(p, b, c)
      @interface.output_text("dump #{p}/#{b}/#{c}")
    end
  end

  class RemoteControllerEngineDouble
    attr_accessor :stepping, :abort_execution
    attr_reader :debugger, :interface, :state, :breakpoint_manager, :runner

    def initialize
      @running = true
      @stepping = false
      @abort_execution = false
      @interface = RemoteControllerInterfaceDouble.new
      @debugger = RemoteControllerDebuggerDouble.new(self)
      @state = RemoteControllerStateDouble.new(7, 3)
      @breakpoint_manager = RemoteControllerBreakpointManagerDouble.new
      @runner = RemoteControllerRunnerDouble.new([4], [5], [6])
    end

    def running?
      @running
    end

    def stop!
      @running = false
    end
  end

  let(:engine) { RemoteControllerEngineDouble.new }
  let(:controller) { described_class.new(engine, id: "test", game_name: "demo") }

  def pause_controller(controller)
    thread = Thread.new { controller.breakpoint_reached(1, 2, 3, reason: "Spec") }
    sleep 0.01 until controller.paused? || !thread.alive?
    thread
  end

  after do
    engine.stop!
  end

  it "blocks on breakpoint until continue is executed" do
    thread = pause_controller(controller)

    expect(controller.state["status"]).to eq("paused")
    expect(controller.state["breakpoint"]).to include(
      "process" => 1,
      "block" => 2,
      "condact" => 3,
      "reason" => "Spec",
    )

    result = controller.execute("c")

    expect(result["ok"]).to be(true)
    expect(result["action"]).to eq("continue")
    expect(result["output"]).to include("handled c at 1/2/3")
    thread.join(1)
    expect(thread).not_to be_alive
    expect(controller.state["status"]).to eq("running")
    expect(controller.state["log"].last["output"]).to include("Continue: engine resumed.")
  end

  it "logs remote debugger exit without changing command output" do
    thread = pause_controller(controller)

    result = controller.execute("x")

    expect(result["ok"]).to be(true)
    expect(result["action"]).to eq("exit")
    expect(result["output"]).to include("handled x at 1/2/3")
    expect(result["output"]).not_to include("Exit: debugger closed")
    thread.join(1)
    expect(thread).not_to be_alive
    expect(controller.state["log"].last["output"]).to include("Exit: debugger closed and current execution aborted.")
  end

  it "keeps the engine paused for inspection commands" do
    thread = pause_controller(controller)

    result = controller.execute("p")

    expect(result["ok"]).to be(true)
    expect(result["action"]).to eq("none")
    expect(result["output"]).to include("handled p at 1/2/3")
    expect(controller.state["status"]).to eq("paused")

    controller.execute("c")
    thread.join(1)
  end

  it "steps by enabling engine stepping and releasing the pause" do
    thread = pause_controller(controller)

    result = controller.execute("s")

    expect(result["ok"]).to be(true)
    expect(result["action"]).to eq("step")
    expect(engine.stepping).to be(true)
    thread.join(1)
    expect(thread).not_to be_alive
  end

  it "does not create a fresh manual pause while a step is already in progress" do
    thread = pause_controller(controller)
    controller.execute("s")
    thread.join(1)

    result = controller.execute("s")

    expect(result["ok"]).to be(false)
    expect(result["output"]).to include("Engine is stepping")
    expect(result["output"]).not_to include("Manual remote request")
  end

  it "can publish a breakpoint without blocking a web step driver" do
    controller.with_nonblocking_breakpoints do
      catch(:remote_debug_pause) do
        controller.breakpoint_reached(2, 3, 4, reason: "Step")
      end
    end

    expect(controller.paused?).to be(true)
    expect(controller.state["breakpoint"]).to include(
      "process" => 2,
      "block" => 3,
      "condact" => 4,
      "reason" => "Step",
    )
  end

  it "pauses explicitly while running" do
    result = controller.execute("pause")

    expect(result["ok"]).to be(true)
    expect(result["action"]).to eq("pause")
    expect(result["output"]).to include("Manual remote request")
    expect(controller.state["status"]).to eq("paused")

    controller.execute("c")
  end

  it "auto-pauses for inspection commands sent while running" do
    result = controller.execute("p")

    expect(result["ok"]).to be(true)
    expect(result["action"]).to eq("none")
    expect(result["output"]).to include("Manual remote request")
    expect(result["output"]).to include("handled p at 4/5/6")
    expect(controller.state["status"]).to eq("paused")

    second_result = controller.execute("p")

    expect(second_result["output"]).not_to include("Manual remote request")
    expect(second_result["output"]).to include("handled p at 4/5/6")

    controller.execute("c")
  end
end
