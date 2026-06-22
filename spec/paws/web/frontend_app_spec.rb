# frozen_string_literal: true

require "open3"
require "rbconfig"
require "spec_helper"

RSpec.describe "web/app.js frontend behavior" do
  let(:root) { File.expand_path("../../..", __dir__) }
  let(:node_script) do
    <<~JS
      const fs = require("fs");
      const vm = require("vm");

      class FakeElement {
        constructor(tagName = "div") {
          this.tagName = tagName;
          this.children = [];
          this.dataset = {};
          this.style = {
            props: {},
            setProperty(name, value) { this.props[name] = value; },
          };
          this.classes = new Set();
          this.classList = {
            add: (...names) => names.forEach((name) => this.classes.add(name)),
            remove: (...names) => names.forEach((name) => this.classes.delete(name)),
            toggle: (name, force) => {
              const shouldAdd = force == null ? !this.classes.has(name) : Boolean(force);
              if (shouldAdd) this.classes.add(name);
              else this.classes.delete(name);
              return shouldAdd;
            },
            contains: (name) => this.classes.has(name),
          };
          this.attributes = {};
          this.textContent = "";
          this.hidden = false;
          this.width = 0;
          this.height = 0;
          this.clientWidth = 256;
          this.clientHeight = 192;
        }

        appendChild(child) {
          this.children.push(child);
          return child;
        }

        setAttribute(name, value) {
          this.attributes[name] = value;
        }

        addEventListener() {}
        removeAttribute() {}
        focus() {}
        querySelectorAll() { return []; }

        getContext() {
          return {
            imageSmoothingEnabled: false,
            fillStyle: "#000",
            fillRect() {},
            clearRect() {},
            putImageData() {},
            getImageData() { return { data: new Uint8ClampedArray(8 * 8 * 4) }; },
            createImageData(width, height) { return { data: new Uint8ClampedArray(width * height * 4) }; },
            drawImage() {},
            save() {},
            restore() {},
            fillText() {},
          };
        }
      }

      const elements = new Map();
      const gameShell = new FakeElement("main");
      const documentStub = {
        documentElement: new FakeElement("html"),
        getElementById(id) {
          if (!elements.has(id)) elements.set(id, new FakeElement(id === "screen" ? "canvas" : "div"));
          return elements.get(id);
        },
        querySelector() { return gameShell; },
        querySelectorAll() { return []; },
        createElement(tagName) { return new FakeElement(tagName); },
        createTextNode(text) {
          const node = new FakeElement("#text");
          node.textContent = text;
          return node;
        },
        addEventListener() {},
      };

      const context = {
        console,
        document: documentStub,
        window: {
          addEventListener() {},
          requestAnimationFrame(callback) { return callback(); },
          setTimeout() { return 1; },
          clearTimeout() {},
          getComputedStyle() { return { paddingLeft: "0", paddingRight: "0", paddingTop: "0", paddingBottom: "0" }; },
        },
        ResizeObserver: class { observe() {} },
        Image: class {},
        fetch: async () => ({ ok: true, text: async () => JSON.stringify({ events: [{ type: "session.ready", session_id: "test" }] }) }),
        URLSearchParams: class { get() { return null; } },
        Uint8ClampedArray,
        Map,
        Promise,
        Number,
        String,
        RegExp,
        Error,
        Math,
        Array,
        JSON,
      };
      context.globalThis = context;

      vm.createContext(context);
      vm.runInContext(fs.readFileSync("web/app.js", "utf8"), context);
      vm.runInContext(`
        defaultTextCharsetId = 2;
        activeCharsetId = 2;
        charsetBanks = {
          "1": {
            "32": ["00000000","00000000","00000000","00000000","00000000","00000000","00000000","00000000"],
            "65": ["01111110","01000010","01000010","01111110","01000010","01000010","01000010","00000000"]
          }
        };
        charsetBankIds = [1];
        const host = document.createElement("div");
        appendRichText(host, "{1}A A", activeCharsetId);
        globalThis.__result = host.children.map((child) => ({
          tagName: child.tagName,
          className: child.className || "",
          textContent: child.textContent || ""
        }));
      `, context);

      const result = context.__result;
      const spaceGlyphs = result.filter((child) => child.className === "inline-spectrum-glyph" && child.textContent === " ");
      const hasWbr = result.some((child) => child.tagName === "wbr");
      const textSpaces = result.filter((child) => child.textContent === " ");
      if (spaceGlyphs.length !== 0 || !hasWbr || textSpaces.length !== 1) {
        console.error(JSON.stringify(result));
        process.exit(1);
      }

      vm.runInContext(`
        const positionedLine = document.createElement("div");
        positionedLine.className = "screen-text-line";
        appendRichText(positionedLine, "{paper:blue}     ", activeCharsetId);
        globalThis.__paperRunResult = positionedLine.children.map((child) => ({
          className: child.className || "",
          textContent: child.textContent || "",
          width: child.style && child.style.width
        }));
      `, context);

      if (
        context.__paperRunResult.length !== 1 ||
        context.__paperRunResult[0].className !== "screen-paper-run" ||
        context.__paperRunResult[0].textContent !== "" ||
        context.__paperRunResult[0].width !== "calc(5 * var(--screen-cell-width, 8px))"
      ) {
        console.error(JSON.stringify(context.__paperRunResult));
        process.exit(1);
      }

      vm.runInContext(`
        const blankRows = Array.from({ length: 192 }, () => "0".repeat(256));
        const blankAttributes = Array.from(
          { length: 24 },
          () => Array.from({ length: 32 }, () => ({ ink: 7, paper: 0, bright: false, flash: false }))
        );
        const frame = {
          type: "screen.frame",
          picture_id: 1,
          logical_width: 256,
          logical_height: 192,
          visible_height: 192,
          full_screen: true,
          rows: blankRows,
          attributes: blankAttributes
        };

        textRenderer = "pc";
        drawFrame(frame);
        const pcFullScreen = gameShell.classList.contains("screen-full");
        const pcCellWidth = screenText.style.props["--screen-cell-width"];
        const pcCellHeight = screenText.style.props["--screen-cell-height"];
        textRenderer = "spectrum";
        drawFrame(frame);
        const spectrumFullScreen = gameShell.classList.contains("screen-full");
        textRenderer = "pc";
        inputMode = "key";
        graphicsPane.hidden = false;
        transcript.textContent = "";
        updatePcKeyFullLayout();
        const pcKeyFull = gameShell.classList.contains("pc-key-full");
        inputMode = "line";
        updatePcKeyFullLayout();
        const pcLineFull = gameShell.classList.contains("pc-key-full");
        globalThis.__layoutResult = { pcFullScreen, pcCellWidth, pcCellHeight, spectrumFullScreen, pcKeyFull, pcLineFull };
      `, context);

      if (!context.__layoutResult.pcFullScreen || context.__layoutResult.pcCellWidth !== "8px" || context.__layoutResult.pcCellHeight !== "8px" || !context.__layoutResult.spectrumFullScreen || !context.__layoutResult.pcKeyFull || context.__layoutResult.pcLineFull) {
        console.error(JSON.stringify(context.__layoutResult));
        process.exit(1);
      }

      vm.runInContext(`
        const charsetCalls = [];
        drawScreenChar = (char, row, col, style, byte = null) => {
          if (char !== " ") charsetCalls.push({ char, row, col, charset: style.charset, byte });
        };
        textRenderer = "spectrum";
        activeCharsetId = 2;
        screenTextCharsetId = 2;
        positionedScreenTextCharsetId = 2;
        textWindowStartRow = 17;
        drawScreenText({ text: "{1}AB", row: 5, col: 0, newline: false, ink: "white", paper: "black", bright: false, flash: false });
        drawScreenText({ text: "CD", row: 18, col: 0, newline: false, ink: "white", paper: "black", bright: false, flash: false });
        drawScreenText({ text: "EF", row: 6, col: 0, newline: false, ink: "white", paper: "black", bright: false, flash: false });
        globalThis.__positionedCharsetResult = charsetCalls;
      `, context);

      const positionedCharset = context.__positionedCharsetResult;
      if (
        positionedCharset.length !== 6 ||
        positionedCharset[0].charset !== 1 ||
        positionedCharset[1].charset !== 1 ||
        positionedCharset[2].charset !== 2 ||
        positionedCharset[3].charset !== 2 ||
        positionedCharset[4].charset !== 1 ||
        positionedCharset[5].charset !== 1
      ) {
        console.error(JSON.stringify(positionedCharset));
        process.exit(1);
      }

      vm.runInContext(`
        const mirroredCalls = [];
        drawScreenChar = (char, row, col, style, byte = null) => {
          mirroredCalls.push({ char, row, col, style, byte });
        };
        textRenderer = "spectrum";
        lineInputOrigin = { row: 22, col: 0 };
        lineInputStyle = { ink: "cyan", paper: null, bright: false, flash: false, charset: null };
        lineInputCursorStyle = { ink: "cyan", paper: null, bright: false, flash: true, charset: 5 };
        lineInputCursorGlyph = 144;
        mirroredInputLength = 0;
        drawMirroredInput("AB");
        const beforeCommit = mirroredCalls.slice();
        commandInput.value = "AB";
        commitMirroredInput();
        globalThis.__mirroredResult = { beforeCommit, afterCommit: mirroredCalls.slice(beforeCommit.length) };
        globalThis.__promptEchoResult = isPromptEcho("{ink:cyan}{flash:0}> ABRIR{ink:white}");
      `, context);

      const mirrored = context.__mirroredResult.beforeCommit;
      const committed = context.__mirroredResult.afterCommit;
      if (
        mirrored.length !== 3 ||
        mirrored[0].char !== "A" ||
        mirrored[0].col !== 0 ||
        mirrored[0].style.ink !== "cyan" ||
        mirrored[0].style.flash !== false ||
        mirrored[0].style.charset !== 2 ||
        mirrored[1].char !== "B" ||
        mirrored[1].col !== 1 ||
        mirrored[2].byte !== 144 ||
        mirrored[2].col !== 2 ||
        mirrored[2].style.ink !== "cyan" ||
        mirrored[2].style.flash !== true ||
        committed[committed.length - 1].char !== " " ||
        committed[committed.length - 1].col !== 2 ||
        committed[committed.length - 1].style.ink !== "cyan" ||
        committed[committed.length - 1].style.flash !== false ||
        context.__promptEchoResult !== true
      ) {
        console.error(JSON.stringify({ mirrored, committed, promptEcho: context.__promptEchoResult }));
        process.exit(1);
      }
    JS
  end

  it "keeps blank alternate-charset spaces as text wrap points and PC text visible beside full-height pictures" do
    node = RbConfig::CONFIG["host_os"].match?(/mswin|mingw/) ? "node.exe" : "node"
    _stdout, stderr, status = Open3.capture3(node, "-e", node_script, chdir: root)

    skip "node is not available" if status.exitstatus == 127
    expect(stderr).to eq("")
    expect(status).to be_success
  rescue Errno::ENOENT
    skip "node is not available"
  end
end
