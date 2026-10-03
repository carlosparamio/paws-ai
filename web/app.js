const graphicsPane = document.getElementById("graphicsPane");
const canvas = document.getElementById("screen");
const ctx = canvas.getContext("2d");
const aiScreen = document.getElementById("aiScreen");
const screenText = document.getElementById("screenText");
const transcript = document.getElementById("transcript");
const commandForm = document.getElementById("commandForm");
const commandInput = document.getElementById("commandInput");
const promptMark = document.getElementById("promptMark");
const gameShell = document.querySelector(".game-shell");
const debugPauseOverlay = document.getElementById("debugPauseOverlay");
const debugPauseText = document.getElementById("debugPauseText");

let sessionId = null;
let inputMode = "line";
let pendingKey = false;
let transcriptLineOpen = false;
let debugEnabled = false;
let remoteDebugEnabled = false;
let debugPaused = false;
let debugStepping = false;
let textRenderer = "pc";
let graphicsMode = "original";
let inputTimeoutId = null;
let activeCharsetId = null;
let defaultTextCharsetId = null;
let transcriptCharsetId = null;
let screenTextCharsetId = null;
let positionedScreenTextCharsetId = null;
let charsetBanks = {};
let charsetBankIds = [];
let charsetMetadata = {};
let udgGlyphs = {};
let screenCursor = { row: 0, col: 0 };
let lineInputOrigin = null;
let mirroredInputLength = 0;
let lineInputStyle = null;
let lineInputCursorStyle = null;
let lineInputCursorGlyph = null;
let textWindowStartRow = null;
let spectrumTextDrawnSinceFrame = false;
let spectrumBitmapRows = null;
let spectrumFrameAttributes = null;
let currentScreenStyle = { ink: "white", paper: "black", bright: false, flash: false };
let spectrumFlashPhase = false;
let spectrumFlashTimer = null;
let fitScreenRequest = null;
let currentScreenFullFrame = false;
let currentFrameToken = 0;
let eventQueue = Promise.resolve();
let debugPollId = null;
const aiGraphicsPolls = new Map();

ctx.imageSmoothingEnabled = false;

const spectrumColors = {
  black: "#000000",
  blue: "#0000d7",
  red: "#d70000",
  magenta: "#d700d7",
  green: "#00d700",
  cyan: "#00d7d7",
  yellow: "#d7d700",
  white: "#d7d7d7",
};

const spectrumColorByCode = [
  "#000000",
  "#0000d7",
  "#d70000",
  "#d700d7",
  "#00d700",
  "#00d7d7",
  "#d7d700",
  "#d7d7d7",
];

const brightSpectrumColorByCode = [
  "#000000",
  "#0000ff",
  "#ff0000",
  "#ff00ff",
  "#00ff00",
  "#00ffff",
  "#ffff00",
  "#ffffff",
];

const brightSpectrumColors = {
  black: "#000000",
  blue: "#0000ff",
  red: "#ff0000",
  magenta: "#ff00ff",
  green: "#00ff00",
  cyan: "#00ffff",
  yellow: "#ffff00",
  white: "#ffffff",
};

const spectrumFont = {
  " ": ["00000000", "00000000", "00000000", "00000000", "00000000", "00000000", "00000000", "00000000"],
  "!": ["00011000", "00011000", "00011000", "00011000", "00011000", "00000000", "00011000", "00000000"],
  "\"": ["00100100", "00100100", "00100100", "00000000", "00000000", "00000000", "00000000", "00000000"],
  "%": ["01100010", "01100100", "00001000", "00010000", "00100000", "01000110", "10000110", "00000000"],
  "(": ["00001100", "00010000", "00100000", "00100000", "00100000", "00010000", "00001100", "00000000"],
  ")": ["00110000", "00001000", "00000100", "00000100", "00000100", "00001000", "00110000", "00000000"],
  ".": ["00000000", "00000000", "00000000", "00000000", "00000000", "00011000", "00011000", "00000000"],
  ":": ["00000000", "00011000", "00011000", "00000000", "00011000", "00011000", "00000000", "00000000"],
  "?": ["00111100", "01000010", "00000010", "00001100", "00010000", "00000000", "00010000", "00000000"],
  "0": ["00111100", "01000010", "01000110", "01001010", "01010010", "01100010", "00111100", "00000000"],
  "1": ["00011000", "00101000", "01001000", "00001000", "00001000", "00001000", "01111110", "00000000"],
  "2": ["00111100", "01000010", "00000010", "00001100", "00110000", "01000000", "01111110", "00000000"],
  "3": ["00111100", "01000010", "00000010", "00011100", "00000010", "01000010", "00111100", "00000000"],
  "4": ["00000100", "00001100", "00010100", "00100100", "01111110", "00000100", "00000100", "00000000"],
  "5": ["01111110", "01000000", "01111100", "00000010", "00000010", "01000010", "00111100", "00000000"],
  "6": ["00111100", "01000000", "01000000", "01111100", "01000010", "01000010", "00111100", "00000000"],
  "7": ["01111110", "00000010", "00000100", "00001000", "00010000", "00100000", "00100000", "00000000"],
  "8": ["00111100", "01000010", "01000010", "00111100", "01000010", "01000010", "00111100", "00000000"],
  "9": ["00111100", "01000010", "01000010", "00111110", "00000010", "00000010", "00111100", "00000000"],
  "A": ["00111100", "01000010", "01000010", "01111110", "01000010", "01000010", "01000010", "00000000"],
  "B": ["01111100", "01000010", "01000010", "01111100", "01000010", "01000010", "01111100", "00000000"],
  "C": ["00111100", "01000010", "01000000", "01000000", "01000000", "01000010", "00111100", "00000000"],
  "D": ["01111000", "01000100", "01000010", "01000010", "01000010", "01000100", "01111000", "00000000"],
  "E": ["01111110", "01000000", "01000000", "01111100", "01000000", "01000000", "01111110", "00000000"],
  "F": ["01111110", "01000000", "01000000", "01111100", "01000000", "01000000", "01000000", "00000000"],
  "G": ["00111100", "01000010", "01000000", "01001110", "01000010", "01000010", "00111100", "00000000"],
  "H": ["01000010", "01000010", "01000010", "01111110", "01000010", "01000010", "01000010", "00000000"],
  "I": ["00111110", "00001000", "00001000", "00001000", "00001000", "00001000", "00111110", "00000000"],
  "J": ["00011110", "00000100", "00000100", "00000100", "01000100", "01000100", "00111000", "00000000"],
  "K": ["01000010", "01000100", "01001000", "01110000", "01001000", "01000100", "01000010", "00000000"],
  "L": ["01000000", "01000000", "01000000", "01000000", "01000000", "01000000", "01111110", "00000000"],
  "M": ["01000010", "01100110", "01011010", "01011010", "01000010", "01000010", "01000010", "00000000"],
  "N": ["01000010", "01100010", "01010010", "01001010", "01000110", "01000010", "01000010", "00000000"],
  "O": ["00111100", "01000010", "01000010", "01000010", "01000010", "01000010", "00111100", "00000000"],
  "P": ["01111100", "01000010", "01000010", "01111100", "01000000", "01000000", "01000000", "00000000"],
  "Q": ["00111100", "01000010", "01000010", "01000010", "01001010", "01000100", "00111010", "00000000"],
  "R": ["01111100", "01000010", "01000010", "01111100", "01001000", "01000100", "01000010", "00000000"],
  "S": ["00111100", "01000010", "01000000", "00111100", "00000010", "01000010", "00111100", "00000000"],
  "T": ["01111110", "00011000", "00011000", "00011000", "00011000", "00011000", "00011000", "00000000"],
  "U": ["01000010", "01000010", "01000010", "01000010", "01000010", "01000010", "00111100", "00000000"],
  "V": ["01000010", "01000010", "01000010", "01000010", "01000010", "00100100", "00011000", "00000000"],
  "W": ["01000010", "01000010", "01000010", "01011010", "01011010", "01100110", "01000010", "00000000"],
  "X": ["01000010", "00100100", "00011000", "00011000", "00011000", "00100100", "01000010", "00000000"],
  "Y": ["01000010", "01000010", "00100100", "00011000", "00011000", "00011000", "00011000", "00000000"],
  "Z": ["01111110", "00000100", "00001000", "00010000", "00100000", "01000000", "01111110", "00000000"],
  "a": ["00000000", "00000000", "00111100", "00000010", "00111110", "01000010", "00111110", "00000000"],
  "e": ["00000000", "00000000", "00111100", "01000010", "01111110", "01000000", "00111100", "00000000"],
  "n": ["00000000", "00000000", "01111100", "01000010", "01000010", "01000010", "01000010", "00000000"],
  "p": ["00000000", "00000000", "01111100", "01000010", "01111100", "01000000", "01000000", "00000000"],
  "r": ["00000000", "00000000", "01011100", "01100010", "01000000", "01000000", "01000000", "00000000"],
  "s": ["00000000", "00000000", "00111110", "01000000", "00111100", "00000010", "01111100", "00000000"],
  "t": ["00010000", "00010000", "01111100", "00010000", "00010000", "00010010", "00001100", "00000000"],
  "©": ["01111110", "10000001", "10111001", "10100001", "10100001", "10111001", "10000001", "01111110"],
};

function appendTranscript(text, className = "", append = false, lineOpen = false) {
  let line = append && transcriptLineOpen ? transcript.lastElementChild : null;
  if (!line || line.className !== className) {
    line = document.createElement("div");
    if (className) line.className = className;
    transcript.appendChild(line);
  }
  transcriptCharsetId = appendRichText(line, text, (transcriptCharsetId == null ? activeCharsetId : transcriptCharsetId));
  transcriptLineOpen = lineOpen;
  transcript.scrollTop = transcript.scrollHeight;
  updatePcKeyFullLayout();
}

function appendRichText(parent, text, initialCharset = activeCharsetId) {
  const source = String(text == null ? "" : text);
  const tagPattern = /\{glyph:(\d+):([^}]*)\}|\{(ink|paper|bright|flash):([a-z0-9]+)\}|\{([0-5])\}/gi;
  let index = 0;
  let match;
  let ink = null;
  let paper = null;
  let bright = false;
  let flash = false;
  let charset = initialCharset;

  while ((match = tagPattern.exec(source)) !== null) {
    appendStyledText(parent, source.slice(index, match.index), { ink, paper, bright, flash, charset });

    if (match[1] != null) {
      appendInlineGlyph(parent, Number(match[1]), match[2] || " ", { ink, paper, bright, flash, charset });
    } else if (match[5] != null) {
      charset = Number(match[5]);
    } else {
      const key = match[3].toLowerCase();
      const value = match[4].toLowerCase();
      if (key === "ink") ink = value;
      if (key === "paper") paper = value;
      if (key === "bright") bright = value === "1";
      if (key === "flash") flash = value === "1";
    }

    index = tagPattern.lastIndex;
  }

  appendStyledText(parent, source.slice(index), { ink, paper, bright, flash, charset });
  return charset;
}

function renderGlyphTags(text) {
  return text.replace(/\{glyph:\d+:([^}]*)\}/gi, "$1");
}

function renderLayoutControlTags(text) {
  return text.replace(/(?:\{6\})+/gi, "\n");
}

function appendInlineGlyph(parent, byte, fallback, style) {
  const fallbackChar = fallback[0] || " ";
  const charsetInfo = getCharsetInfo(style.charset);
  const isUdg = Number(byte) >= 144;
  const forceGlyph = !charsetInfo.isText || isUdg;
  if (!forceGlyph && !shouldRenderInlineGlyph(fallbackChar)) {
    appendStyledText(parent, fallbackChar, style);
    return;
  }

  const glyph = charsetGlyph(byte, style.charset);
  if (!glyph) {
    appendStyledText(parent, fallbackChar, { ...style, charset: defaultTextCharsetId });
    return;
  }
  if (fallbackChar.match(/\s/) && !glyphHasInk(glyph)) {
    appendStyledText(parent, fallbackChar, { ...style, charset: defaultTextCharsetId });
    parent.appendChild(document.createElement("wbr"));
    return;
  }

  const glyphCanvas = document.createElement("canvas");
  glyphCanvas.className = "inline-spectrum-glyph";
  glyphCanvas.width = 8;
  glyphCanvas.height = 8;
  glyphCanvas.dataset.byte = String(byte);
  glyphCanvas.dataset.fallback = fallbackChar;
  glyphCanvas.title = `glyph ${byte}: ${fallbackChar}`;
  glyphCanvas.setAttribute("role", "img");
  glyphCanvas.setAttribute("aria-label", fallbackChar);
  if (style.flash) glyphCanvas.classList.add("spectrum-flash");

  const glyphCtx = glyphCanvas.getContext("2d");
  glyphCtx.imageSmoothingEnabled = false;

  if (style.paper && spectrumColors[style.paper]) {
    glyphCtx.fillStyle = cssColorFor(style.paper, false, "#000000");
    glyphCtx.fillRect(0, 0, 8, 8);
  }

  glyphCtx.fillStyle = cssColorFor(style.ink || currentScreenStyle.ink || "white", style.bright, "#d7d7d7");
  glyph.forEach((bits, y) => {
    for (let x = 0; x < 8; x += 1) {
      if (bits[x] === "1") glyphCtx.fillRect(x, y, 1, 1);
    }
  });

  parent.appendChild(glyphCanvas);
}

function glyphHasInk(glyph) {
  return glyph.some((row) => String(row).includes("1"));
}

function appendGlyphTextFallback(parent, text) {
  const fallback = document.createElement("span");
  fallback.className = "glyph-text-fallback";
  fallback.textContent = text;
  parent.appendChild(fallback);
}

function shouldRenderInlineGlyph(char) {
  if (!char || char.length === 0) return false;
  const code = char.charCodeAt(0);
  return code >= 33 && code <= 126 && !/[A-Za-z0-9]/.test(char);
}

function appendStyledText(parent, text, style) {
  if (!text) return;

  const charsetInfo = getCharsetInfo(style.charset);
  if (!charsetInfo.isText) {
    appendCharsetText(parent, text, style);
    return;
  }

  const span = document.createElement("span");
  const cleanText = renderLayoutControlTags(text).replace(/\{[^}]+\}/g, "");
  span.textContent = cleanText;

  if (charsetInfo.isItalic) {
    span.classList.add("spectrum-italic");
  }

  const inkPalette = style.bright ? brightSpectrumColors : spectrumColors;
  if (style.ink && inkPalette[style.ink]) {
    span.style.color = inkPalette[style.ink];
  }
  if (style.paper && spectrumColors[style.paper]) {
    span.style.backgroundColor = spectrumColors[style.paper];
  }
  if (style.flash) span.classList.add("spectrum-flash");
  if (isPositionedScreenTextLine(parent) && style.paper && /^[ ]+$/.test(cleanText)) {
    span.className = "screen-paper-run";
    span.textContent = "";
    span.style.width = `calc(${cleanText.length} * var(--screen-cell-width, 8px))`;
  }

  parent.appendChild(span);
}

function isPositionedScreenTextLine(element) {
  if (!element) return false;
  if (String(element.className || "").split(/\s+/).includes("screen-text-line")) return true;
  if (element.classList && typeof element.classList.contains === "function") {
    return element.classList.contains("screen-text-line");
  }
  return false;
}

function appendCharsetText(parent, text, style) {
  const clean = renderLayoutControlTags(text).replace(/\{[^}]+\}/g, "");
  let fallbackText = "";
  for (const char of clean) {
    if (char === "\r") continue;
    fallbackText += char;
    if (char === "\n") {
      parent.appendChild(document.createTextNode("\n"));
      continue;
    }
    appendInlineGlyph(parent, char.charCodeAt(0), char, style);
  }
  if (fallbackText) appendGlyphTextFallback(parent, fallbackText);
}

async function postJson(url, payload) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const responseText = await response.text();
  let parsed = null;
  if (responseText) {
    try {
      parsed = JSON.parse(responseText);
    } catch (_error) {
      parsed = null;
    }
  }
  if (!response.ok) {
    const serverMessage = parsed && parsed.type === "error" ? parsed.message : responseText;
    const suffix = serverMessage ? `: ${serverMessage}` : "";
    const error = new Error(`${response.status} ${response.statusText}${suffix}`);
    error.status = response.status;
    throw error;
  }
  return parsed || {};
}

async function getJson(url) {
  const response = await fetch(url);
  const responseText = await response.text();
  let parsed = null;
  if (responseText) {
    try {
      parsed = JSON.parse(responseText);
    } catch (_error) {
      parsed = null;
    }
  }
  if (!response.ok) {
    const serverMessage = parsed && parsed.type === "error" ? parsed.message : responseText;
    const suffix = serverMessage ? `: ${serverMessage}` : "";
    const error = new Error(`${response.status} ${response.statusText}${suffix}`);
    error.status = response.status;
    throw error;
  }
  return parsed || {};
}

function handleTransportError(error) {
  clearInputTimeout();
  if (error && error.status === 404 && sessionId) {
    sessionId = null;
    appendTranscript("Sesion web caducada. Recarga la pagina para iniciar una nueva.", "error-line");
    return;
  }

  appendTranscript(`Error: ${error.message}`, "error-line");
}

function drawFrame(frame) {
  currentFrameToken += 1;
  const frameToken = currentFrameToken;
  currentScreenFullFrame = frame.full_screen === true;
  graphicsPane.hidden = false;
  gameShell.classList.remove("no-graphics");
  aiScreen.hidden = true;
  aiScreen.removeAttribute("src");
  const width = frame.logical_width;
  const sourceHeight = frame.logical_height;
  const visibleHeight = Math.max(1, Math.min(frame.visible_height || sourceHeight, sourceHeight));
  const readyAIGraphics = frame.ai_graphics && frame.ai_graphics.state === "ready" && frame.ai_graphics.url;
  const overlaySpectrumFrame = textRenderer === "spectrum" &&
    spectrumTextDrawnSinceFrame &&
    !readyAIGraphics &&
    canvas.width === width &&
    canvas.height === visibleHeight;

  if (!overlaySpectrumFrame) {
    screenText.textContent = "";
    canvas.width = width;
    canvas.height = visibleHeight;
    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, width, visibleHeight);
  }
  canvas.style.visibility = readyAIGraphics ? "hidden" : "visible";

if (!readyAIGraphics) {
  const image = overlaySpectrumFrame ? ctx.getImageData(0, 0, width, visibleHeight) : ctx.createImageData(width, visibleHeight);

  if (overlaySpectrumFrame) {
    ensureSpectrumFramebuffer(width, visibleHeight);
    const authoritativeHeight = frame.base_composited === true
      ? Math.min(visibleHeight, textWindowStartRow == null ? visibleHeight : textWindowStartRow * 8)
      : 0;
    for (let y = 0; y < visibleHeight; y += 1) {
      const paintRows = frame.overlay_rows || frame.rows || [];
      const row = paintRows[y] || "";
      const toggleRow = frame.toggle_rows && frame.toggle_rows[y] ? frame.toggle_rows[y] : "";
      const clearRow = frame.clear_rows && frame.clear_rows[y] ? frame.clear_rows[y] : "";
      for (let x = 0; x < width; x += 1) {
        if (toggleRow[x] === "1" && row[x] === "1") {
          spectrumBitmapRows[y][x] = !spectrumBitmapRows[y][x];
        } else if (clearRow[x] === "1") {
          spectrumBitmapRows[y][x] = false;
        } else if (y < authoritativeHeight) {
          spectrumBitmapRows[y][x] = (frame.rows[y] || "")[x] === "1";
        } else if (row[x] === "1") {
          spectrumBitmapRows[y][x] = true;
        }
      }
    }

    const attrRows = Math.ceil(visibleHeight / 8);
    const attrCols = Math.ceil(width / 8);
    for (let ay = 0; ay < attrRows; ay += 1) {
      for (let ax = 0; ax < attrCols; ax += 1) {
        const attr = frameCellAttribute(frame, ax, ay);
        const authoritativeCell = ay * 8 < authoritativeHeight;
        if (!authoritativeCell && sameFrameAttribute(attr, defaultFrameAttribute()) && !frameCellHasInk(frame, ax, ay, width, visibleHeight) && !frameCellHasClear(frame, ax, ay, width, visibleHeight) && !frameCellHasToggle(frame, ax, ay, width, visibleHeight)) continue;

        spectrumFrameAttributes[ay][ax] = attr;
        redrawSpectrumCell(image, width, visibleHeight, ax, ay, attr);
      }
    }
  } else {
    spectrumBitmapRows = frameBitmapRows(frame, width, visibleHeight);
    spectrumFrameAttributes = cloneFrameAttributes(frame, width, visibleHeight);
    for (let y = 0; y < visibleHeight; y += 1) {
      for (let x = 0; x < width; x += 1) {
        writeImagePixel(image, width, x, y, spectrumPixelColor(frameAttribute(frame, x, y), spectrumBitmapRows[y][x]));
      }
    }
  }

  ctx.putImageData(image, 0, 0);
}

  if (!overlaySpectrumFrame) {
    spectrumTextDrawnSinceFrame = false;
    screenTextCharsetId = activeCharsetId;
    positionedScreenTextCharsetId = activeCharsetId;
    textWindowStartRow = frame.text_window_start_row == null ? null : Number(frame.text_window_start_row);
    if (textWindowStartRow != null) screenCursor = { row: textWindowStartRow, col: 0 };
    if (!readyAIGraphics) clearTextWindow(frame, width, visibleHeight);
  }

  document.documentElement.style.setProperty("--visible-height", String(visibleHeight));
  document.documentElement.style.setProperty("--screen-height", String(visibleHeight));
  document.documentElement.style.setProperty("--screen-height-px", `${visibleHeight}px`);
  setScreenLayout(visibleHeight, currentScreenFullFrame);
  requestFitScreen();

  if (debugEnabled) {
    appendTranscript(
      `[debug] picture=${frame.picture_id} visible_height=${visibleHeight} commands=${frame.commands_rendered}/${frame.commands_seen} skipped=${frame.commands_skipped} pixels=${frame.pixels_set}`,
      "debug-line",
    );
    if (frame.ai_graphics) appendTranscript(`[debug] ai-graphics ${JSON.stringify(frame.ai_graphics)}`, "debug-line");
  }

  handleAIGraphics(frame, frameToken);
}

function handleAIGraphics(frame, frameToken) {
  const ai = frame.ai_graphics;
  if (!ai) return;

  if (ai.state === "ready" && ai.url) {
    drawAIGraphicsImage(ai.url, frameToken);
    return;
  }

  if (ai.state === "pending" && ai.status_url) {
    pollAIGraphics(ai.status_url, frameToken);
  } else if (debugEnabled && ai.state === "error") {
    appendTranscript(`[debug] ai-graphics error: ${ai.message || "unknown error"}`, "debug-line");
  }
}

function pollAIGraphics(statusUrl, frameToken) {
  if (aiGraphicsPolls.has(statusUrl)) return;

  const poll = async () => {
    try {
      const response = await fetch(statusUrl);
      if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);

      const status = await response.json();
      if (status.state === "ready" && status.url) {
        aiGraphicsPolls.delete(statusUrl);
        if (debugEnabled) appendTranscript(`[debug] ai-graphics ready ${JSON.stringify(status)}`, "debug-line");
        if (frameToken === currentFrameToken) drawAIGraphicsImage(status.url, frameToken);
        return;
      }
      if (status.state === "error") {
        aiGraphicsPolls.delete(statusUrl);
        if (debugEnabled) appendTranscript(`[debug] ai-graphics error: ${status.message || "unknown error"}`, "debug-line");
        return;
      }
    } catch (error) {
      aiGraphicsPolls.delete(statusUrl);
      if (debugEnabled) appendTranscript(`[debug] ai-graphics poll failed: ${error.message}`, "debug-line");
      return;
    }

    const timeoutId = window.setTimeout(poll, 2000);
    aiGraphicsPolls.set(statusUrl, timeoutId);
  };

  const timeoutId = window.setTimeout(poll, 2000);
  aiGraphicsPolls.set(statusUrl, timeoutId);
}

function drawAIGraphicsImage(url, frameToken) {
  const image = new Image();
  image.onload = () => {
    if (frameToken !== currentFrameToken) return;

    aiScreen.src = url;
    aiScreen.hidden = false;
  };
  image.onerror = () => {
    if (frameToken !== currentFrameToken) return;

    canvas.style.visibility = "visible";
    aiScreen.hidden = true;
    if (debugEnabled) appendTranscript(`[debug] ai-graphics image load failed: ${url}`, "debug-line");
  };
  image.src = url;
}

function appendScreenText(event) {
  graphicsPane.hidden = false;
  gameShell.classList.remove("no-graphics");

  if (canvas.width === 0 || canvas.height === 0) {
    resetBlankScreen();
  }

  setScreenLayout(canvas.height, currentScreenFullFrame || (textRenderer === "spectrum" && canvas.height >= 192));
  if (textRenderer === "spectrum") {
    drawScreenText(event);
  } else {
    drawPositionedScreenText(event);
  }
  requestFitScreen();
}

function drawPositionedScreenText(event) {
  const line = document.createElement("div");
  line.className = "screen-text-line";
  line.dataset.row = String(Number(event.row || 0));
  line.style.setProperty("--row", String(Number(event.row || 0)));
  line.style.setProperty("--col", String(Number(event.col || 0)));
  screenTextCharsetId = appendRichText(line, event.text || "", (screenTextCharsetId == null ? activeCharsetId : screenTextCharsetId));
  screenText.appendChild(line);
  screenText.scrollTop = screenText.scrollHeight;
}

function drawScreenText(event) {
  const startRow = Number(event.row || 0);
  const flowTextEvent = textWindowStartRow == null || startRow >= textWindowStartRow;
  const charsetState = flowTextEvent ? screenTextCharsetId : positionedScreenTextCharsetId;
  const defaultStyle = {
    ink: event.ink || currentScreenStyle.ink || "white",
    paper: event.paper || currentScreenStyle.paper || "black",
    bright: event.bright == null ? currentScreenStyle.bright === true : event.bright === true,
    flash: event.flash == null ? currentScreenStyle.flash === true : event.flash === true,
    charset: (charsetState == null ? activeCharsetId : charsetState),
  };
  let row = startRow;
  let col = Number(event.col || 0);

  const segments = parseRichSegments(event.text || "", defaultStyle);
  const allTokens = [];
  for (const segment of segments) {
    for (const token of screenTextTokens(segment.text)) {
      if (token.char === "\r") continue;
      allTokens.push({ token, style: segment.style });
    }
  }

  for (let i = 0; i < allTokens.length; i += 1) {
    const { token, style } = allTokens[i];
    const char = token.char;
    if (char === "\n") {
      clearScreenCells(row, col, 32, style);
      const hasMoreChars = allTokens.slice(i + 1).some((item) => item.token.char !== "\n" && item.token.char !== "\r");
      if (hasMoreChars) {
        row += 1;
        col = 0;
        while (row >= 24) {
          scrollTextWindow(defaultStyle);
          row -= 1;
        }
      } else {
        row = Math.min(23, row + 1);
        col = 0;
      }
      continue;
    }

    if (col >= 32) {
      row += 1;
      col = 0;
    }
    while (row >= 24) {
      scrollTextWindow(defaultStyle);
      row -= 1;
    }

    drawScreenChar(char, row, col, style, token.byte);
    col += 1;
  }

  if (event.newline !== false) {
    clearScreenCells(row, col, 32, finalRichStyle(event.text || "", defaultStyle));
    row = Math.min(23, row + 1);
    col = 0;
  }

  const finalCharset = finalRichStyle(event.text || "", defaultStyle).charset;
  if (flowTextEvent) {
    screenTextCharsetId = finalCharset;
  } else {
    positionedScreenTextCharsetId = finalCharset;
  }
  screenCursor = { row, col };
  spectrumTextDrawnSinceFrame = true;
}

function clearScreenCells(row, col, endCol, style) {
  if (row < 0 || row >= 24) return;

  for (let cellCol = Math.max(0, col); cellCol < Math.min(32, endCol); cellCol += 1) {
    drawScreenChar(" ", row, cellCol, style);
  }
}

function drawMirroredInput(text) {
  if (textRenderer !== "spectrum" || !lineInputOrigin) return;

  const textStyle = {
    ...currentScreenStyle,
    ...(lineInputStyle || {}),
    flash: lineInputStyle && lineInputStyle.flash === true,
    charset: activeCharsetId,
  };
  const cursorStyle = {
    ...textStyle,
    ...(lineInputCursorStyle || {}),
    flash: lineInputCursorStyle && lineInputCursorStyle.flash === true,
  };
  const inputText = String(text || "");
  const length = Math.max(mirroredInputLength + 1, inputText.length + 1);
  let row = lineInputOrigin.row;
  let col = lineInputOrigin.col;

  for (let index = 0; index < length; index += 1) {
    if (col >= 32) {
      row += 1;
      col = 0;
    }
    if (row >= 24) break;

    if (index < inputText.length) {
      drawScreenChar(inputText[index], row, col, textStyle);
    } else if (index === inputText.length) {
      const cursorChar = lineInputCursorGlyph == null ? "_" : "?";
      drawScreenChar(cursorChar, row, col, cursorStyle, lineInputCursorGlyph);
    } else {
      drawScreenChar(" ", row, col, textStyle);
    }
    col += 1;
  }
  mirroredInputLength = inputText.length;
}

function commitMirroredInput() {
  if (textRenderer !== "spectrum" || !lineInputOrigin) return;

  drawMirroredInput(commandInput.value);
  const textStyle = {
    ...currentScreenStyle,
    ...(lineInputStyle || {}),
    flash: false,
    charset: activeCharsetId,
  };
  const inputText = String(commandInput.value || "");
  let row = lineInputOrigin.row;
  let col = lineInputOrigin.col + inputText.length;
  while (col >= 32) {
    row += 1;
    col -= 32;
  }
  if (row < 24) drawScreenChar(" ", row, col, textStyle);
  mirroredInputLength = inputText.length;
}

function parseRichSegments(text, initialStyle) {
  const source = String(text == null ? "" : text);
  const tagPattern = /\{(ink|paper|bright|flash):([a-z0-9]+)\}|\{([0-5])\}/gi;
  const segments = [];
  let index = 0;
  let match;
  const style = { ...initialStyle };

  while ((match = tagPattern.exec(source)) !== null) {
    pushTextSegment(segments, source.slice(index, match.index), style);

    if (match[3] != null) {
      style.charset = Number(match[3]);
    } else {
      const key = match[1].toLowerCase();
      const value = match[2].toLowerCase();
      if (key === "ink") style.ink = value;
      if (key === "paper") style.paper = value;
      if (key === "bright") style.bright = value === "1";
      if (key === "flash") style.flash = value === "1";
    }

    index = tagPattern.lastIndex;
  }

  pushTextSegment(segments, source.slice(index), style);
  return segments;
}

function finalRichStyle(text, initialStyle) {
  const source = String(text == null ? "" : text);
  const tagPattern = /\{(ink|paper|bright|flash):([a-z0-9]+)\}|\{([0-5])\}/gi;
  const style = { ...initialStyle };
  let match;

  while ((match = tagPattern.exec(source)) !== null) {
    if (match[3] != null) {
      style.charset = Number(match[3]);
    } else {
      const key = match[1].toLowerCase();
      const value = match[2].toLowerCase();
      if (key === "ink") style.ink = value;
      if (key === "paper") style.paper = value;
      if (key === "bright") style.bright = value === "1";
      if (key === "flash") style.flash = value === "1";
    }
  }

  return style;
}

function pushTextSegment(segments, text, style) {
  if (!text) return;

  segments.push({
    text,
    style: { ...style },
  });
}

function screenTextTokens(text) {
  const tokens = [];
  const source = String(text == null ? "" : text);
  const glyphPattern = /\{glyph:(\d+):([^}]*)\}/gi;
  let index = 0;
  let match;

  while ((match = glyphPattern.exec(source)) !== null) {
    appendPlainScreenTokens(tokens, source.slice(index, match.index));
    const fallback = match[2] || " ";
    tokens.push({ char: fallback[0] || " ", byte: Number(match[1]) });
    index = glyphPattern.lastIndex;
  }

  appendPlainScreenTokens(tokens, source.slice(index));
  return tokens;
}

function appendPlainScreenTokens(tokens, text) {
  const clean = renderLayoutControlTags(text).replace(/\{[^}]+\}/g, "");
  for (const char of clean) {
    tokens.push({ char, byte: null });
  }
}

function colorCodeForName(name, fallback) {
  const names = ["black", "blue", "red", "magenta", "green", "cyan", "yellow", "white"];
  const index = names.indexOf(String(name || "").toLowerCase());
  return index >= 0 ? index : fallback;
}

function styleToFrameAttribute(style) {
  return {
    ink: colorCodeForName(style && style.ink, 7),
    paper: colorCodeForName(style && style.paper, 0),
    bright: style && style.bright === true,
    flash: style && style.flash === true,
  };
}

function drawScreenChar(char, row, col, style, byte = null) {
  const x0 = col * 8;
  const y0 = row * 8;
  const paperColor = cssColorFor(style.paper, false, "#000000");
  const inkColor = cssColorFor(style.ink, style.bright, "#d7d7d7");
  const glyphByte = byte == null ? screenByteForChar(char) : byte;
  const glyph = charsetGlyph(glyphByte, style.charset) || spectrumFont[char];
  const attr = styleToFrameAttribute(style || {});
  if (attr.flash) ensureSpectrumFlashTimer();

  ensureSpectrumFramebuffer(canvas.width || 256, canvas.height || 192);
  if (spectrumFrameAttributes[row] && spectrumFrameAttributes[row][col]) {
    spectrumFrameAttributes[row][col] = attr;
  }

  ctx.fillStyle = paperColor;
  ctx.fillRect(x0, y0, 8, 8);

  for (let y = 0; y < 8; y += 1) {
    for (let x = 0; x < 8; x += 1) {
      if (spectrumBitmapRows[y0 + y] && x0 + x < spectrumBitmapRows[y0 + y].length) {
        spectrumBitmapRows[y0 + y][x0 + x] = false;
      }
    }
  }

  if (byte == null && char === " ") return;

  ctx.fillStyle = inkColor;
  if (!glyph) {
    drawFallbackScreenChar(char, x0, y0);
    return;
  }

  glyph.forEach((bits, y) => {
    for (let x = 0; x < 8; x += 1) {
      if (bits[x] === "1") {
        ctx.fillRect(x0 + x, y0 + y, 1, 1);
        if (spectrumBitmapRows[y0 + y] && x0 + x < spectrumBitmapRows[y0 + y].length) {
          spectrumBitmapRows[y0 + y][x0 + x] = true;
        }
      }
    }
  });
}

function clearTextWindow(frame, width, visibleHeight) {
  if (textWindowStartRow == null) return;

  const y = Math.max(0, Math.min(visibleHeight, textWindowStartRow * 8));
  if (y >= visibleHeight) return;

  ctx.fillStyle = cssColorFor(frame.text_window_paper || "black", false, "#000000");
  ctx.fillRect(0, y, width, visibleHeight - y);

  ensureSpectrumFramebuffer(width, visibleHeight);
  const attr = styleToFrameAttribute({
    ink: frame.text_window_ink || "white",
    paper: frame.text_window_paper || "black",
    bright: false,
    flash: false,
  });
  for (let py = y; py < visibleHeight; py += 1) {
    spectrumBitmapRows[py].fill(false);
  }
  for (let ay = textWindowStartRow; ay < Math.ceil(visibleHeight / 8); ay += 1) {
    for (let ax = 0; ax < Math.ceil(width / 8); ax += 1) {
      spectrumFrameAttributes[ay][ax] = attr;
    }
  }
}

function scrollTextWindow(style = currentScreenStyle) {
  const startRow = textWindowStartRow == null ? 0 : textWindowStartRow;
  if (canvas.height < 192) return;

  const y = Math.max(0, Math.min(canvas.height, startRow * 8));
  const lineHeight = 8;
  const copyHeight = canvas.height - y - lineHeight;
  ensureSpectrumFramebuffer(canvas.width, canvas.height);
  if (copyHeight > 0) {
    const imageData = ctx.getImageData(0, y + lineHeight, canvas.width, copyHeight);
    ctx.putImageData(imageData, 0, y);
    for (let py = y; py < y + copyHeight; py += 1) {
      spectrumBitmapRows[py] = spectrumBitmapRows[py + lineHeight].slice();
    }
    for (let ay = startRow; ay < 23; ay += 1) {
      spectrumFrameAttributes[ay] = spectrumFrameAttributes[ay + 1].map((attr) => ({ ...attr }));
    }
  }
  const blankAttr = styleToFrameAttribute(style || {});
  ctx.fillStyle = cssColorFor(style.paper || "black", false, "#000000");
  ctx.fillRect(0, canvas.height - lineHeight, canvas.width, lineHeight);
  for (let py = canvas.height - lineHeight; py < canvas.height; py += 1) {
    spectrumBitmapRows[py].fill(false);
  }
  spectrumFrameAttributes[23] = spectrumFrameAttributes[23].map(() => blankAttr);
}

function scrollScreenText(lines = 1) {
  if (textRenderer === "spectrum") {
    for (let i = 0; i < lines; i += 1) {
      scrollTextWindow(currentScreenStyle);
    }
    return;
  }

  const startRow = textWindowStartRow == null ? 0 : textWindowStartRow;
  for (const line of Array.from(screenText.querySelectorAll(".screen-text-line"))) {
    const currentRow = Number(line.dataset.row || 0);
    if (currentRow < startRow) continue;

    const nextRow = currentRow - lines;
    if (nextRow < startRow) {
      line.remove();
    } else {
      line.dataset.row = String(nextRow);
      line.style.setProperty("--row", String(nextRow));
    }
  }
}

function drawFallbackScreenChar(char, x0, y0) {
  ctx.save();
  ctx.font = "8px monospace";
  ctx.textBaseline = "top";
  ctx.fillText(char, x0, y0 - 1);
  ctx.restore();
}

function screenByteForChar(char) {
  if (!char || char.length === 0) return null;

  const code = char.charCodeAt(0);
  return code >= 32 && code <= 127 ? code : null;
}

function charsetGlyph(byte, charsetId = activeCharsetId) {
  if (byte == null) return null;

  const bank = charsetBankFor(charsetId);
  const bytes = (bank && bank[String(byte)]) || udgGlyphs[String(byte)];
  if (!bytes || bytes.length !== 8) return null;

  return bytes.map((row) => Number(row).toString(2).padStart(8, "0").slice(-8));
}

function charsetBankFor(charsetId) {
  if (charsetId == null) return null;

  const direct = charsetBanks[String(charsetId)];
  if (direct) return direct;

  const selector = Number(charsetId);
  if (!Number.isInteger(selector) || selector <= 0 || charsetBankIds.length === 0) return null;

  const wrappedId = charsetBankIds[(selector - 1) % charsetBankIds.length];
  return charsetBanks[String(wrappedId)] || null;
}

function getCharsetInfo(charsetId) {
  if (charsetId == null || charsetId === defaultTextCharsetId) {
    return { isText: true, isItalic: false };
  }

  const idStr = String(charsetId);
  const meta = (charsetMetadata && (charsetMetadata[idStr] || charsetMetadata[Number(charsetId)])) || null;
  if (meta) {
    const isText = meta.type === "text" || meta.is_text === true || meta.isText === true || meta.italic === true || meta.style === "italic";
    const isItalic = meta.italic === true || meta.style === "italic" || meta.type === "italic";
    return { isText, isItalic };
  }

  const bank = charsetBankFor(charsetId);
  if (!bank) {
    return { isText: true, isItalic: false };
  }

  let letterCount = 0;
  for (let code = 65; code <= 90; code += 1) {
    const glyph = bank[String(code)];
    if (glyph && glyphHasInk(glyph)) letterCount += 1;
  }
  for (let code = 97; code <= 122; code += 1) {
    const glyph = bank[String(code)];
    if (glyph && glyphHasInk(glyph)) letterCount += 1;
  }

  const isText = letterCount >= 20;
  const isItalic = isText && Number(charsetId) === 2;

  return { isText, isItalic };
}

function applyScreenCharset(event) {
  activeCharsetId = event.active == null ? null : Number(event.active);
  defaultTextCharsetId = activeCharsetId;
  transcriptCharsetId = activeCharsetId;
  screenTextCharsetId = activeCharsetId;
  positionedScreenTextCharsetId = activeCharsetId;
  charsetBanks = {};
  charsetBankIds = [];
  charsetMetadata = event.metadata || {};
  udgGlyphs = event.udgs && event.udgs.glyphs ? event.udgs.glyphs : {};

  const entries = event.charsets && Array.isArray(event.charsets.entries)
    ? event.charsets.entries
    : [];
  for (const entry of entries) {
    const id = Number(entry.id);
    charsetBanks[String(id)] = entry.glyphs || {};
    if (Number.isInteger(id)) charsetBankIds.push(id);
  }
  charsetBankIds.sort((left, right) => left - right);
}

function selectScreenCharset(event) {
  activeCharsetId = event.active == null ? null : Number(event.active);
  transcriptCharsetId = activeCharsetId;
  screenTextCharsetId = activeCharsetId;
  positionedScreenTextCharsetId = activeCharsetId;
}

function cssColorFor(name, bright, fallback) {
  const palette = bright ? brightSpectrumColors : spectrumColors;
  return palette[name] || fallback;
}

function resetBlankScreen() {
  const width = 256;
  const height = 192;
  canvas.width = width;
  canvas.height = height;
  aiScreen.hidden = true;
  aiScreen.removeAttribute("src");
  ctx.imageSmoothingEnabled = false;
  ctx.clearRect(0, 0, width, height);
  setScreenLayout(height, true);
  currentScreenFullFrame = true;
  textWindowStartRow = null;
  screenCursor = { row: 0, col: 0 };
  lineInputOrigin = null;
  mirroredInputLength = 0;
  lineInputStyle = null;
  lineInputCursorStyle = null;
  lineInputCursorGlyph = null;
  spectrumTextDrawnSinceFrame = false;
  spectrumBitmapRows = null;
  spectrumFrameAttributes = null;
  positionedScreenTextCharsetId = activeCharsetId;
}

function setScreenLayout(visibleHeight, fullScreen = false) {
  document.documentElement.style.setProperty("--visible-height", String(visibleHeight));
  document.documentElement.style.setProperty("--screen-height", String(visibleHeight));
  document.documentElement.style.setProperty("--screen-height-px", `${visibleHeight}px`);
  graphicsPane.classList.toggle("tall", visibleHeight > 128);
  gameShell.classList.toggle("screen-full", fullScreen);
  requestFitScreen();
}

function requestFitScreen() {
  if (fitScreenRequest != null) return;

  fitScreenRequest = window.requestAnimationFrame(() => {
    fitScreenRequest = null;
    fitScreenToPane();
  });
}

function waitForPaint() {
  return new Promise((resolve) => {
    window.requestAnimationFrame(() => {
      window.requestAnimationFrame(() => resolve());
    });
  });
}

function fitScreenToPane() {
  if (graphicsPane.hidden || canvas.width <= 0 || canvas.height <= 0) return;

  const style = window.getComputedStyle(graphicsPane);
  const horizontalPadding = parseFloat(style.paddingLeft || "0") + parseFloat(style.paddingRight || "0");
  const verticalPadding = parseFloat(style.paddingTop || "0") + parseFloat(style.paddingBottom || "0");
  const availableWidth = Math.max(1, graphicsPane.clientWidth - horizontalPadding);
  const availableHeight = Math.max(1, graphicsPane.clientHeight - verticalPadding);
  const scale = Math.min(availableWidth / canvas.width, availableHeight / canvas.height);
  const fittedWidth = Math.max(1, Math.floor(canvas.width * scale));
  const fittedHeight = Math.max(1, Math.floor(canvas.height * scale));

  canvas.style.width = `${fittedWidth}px`;
  canvas.style.height = `${fittedHeight}px`;
  aiScreen.style.width = `${fittedWidth}px`;
  aiScreen.style.height = `${fittedHeight}px`;
  screenText.style.width = `${fittedWidth}px`;
  screenText.style.height = `${fittedHeight}px`;
  const screenCellSize = fittedWidth / 32;
  screenText.style.setProperty("--screen-cell-width", `${screenCellSize}px`);
  screenText.style.setProperty("--screen-cell-height", `${screenCellSize}px`);
}

function normalizeFrameAttribute(attr) {
  return {
    ink: Number(attr && attr.ink != null ? attr.ink : 0) & 7,
    paper: Number(attr && attr.paper != null ? attr.paper : 7) & 7,
    bright: attr && attr.bright === true,
    flash: attr && attr.flash === true,
  };
}

function defaultFrameAttribute() {
  return { ink: 7, paper: 0, bright: false, flash: false };
}

function frameAttribute(frame, x, y) {
  const attributes = frame.attributes || [];
  const attrRow = attributes[Math.floor(y / 8)] || [];
  return normalizeFrameAttribute(attrRow[Math.floor(x / 8)] || defaultFrameAttribute());
}

function frameCellAttribute(frame, ax, ay) {
  const attributes = frame.attributes || [];
  const attrRow = attributes[ay] || [];
  return normalizeFrameAttribute(attrRow[ax] || defaultFrameAttribute());
}

function sameFrameAttribute(left, right) {
  return Number(left.ink) === Number(right.ink) &&
    Number(left.paper) === Number(right.paper) &&
    left.bright === right.bright &&
    left.flash === right.flash;
}

function ensureSpectrumFlashTimer() {
  if (spectrumFlashTimer != null) return;

  spectrumFlashTimer = window.setInterval(() => {
    spectrumFlashPhase = !spectrumFlashPhase;
    redrawFlashingSpectrumCells();
  }, 500);
}

function redrawFlashingSpectrumCells() {
  if (!spectrumFrameAttributes || !spectrumBitmapRows || canvas.width <= 0 || canvas.height <= 0) return;

  const image = ctx.getImageData(0, 0, canvas.width, canvas.height);
  let changed = false;
  spectrumFrameAttributes.forEach((row, ay) => {
    row.forEach((attr, ax) => {
      if (!attr || attr.flash !== true) return;

      changed = true;
      redrawSpectrumCell(image, canvas.width, canvas.height, ax, ay, attr);
    });
  });
  if (changed) ctx.putImageData(image, 0, 0);
}

function cloneFrameAttributes(frame, width, visibleHeight) {
  const rows = Math.ceil(visibleHeight / 8);
  const cols = Math.ceil(width / 8);
  return Array.from({ length: rows }, (_, ay) => (
    Array.from({ length: cols }, (_, ax) => {
      const attr = frameCellAttribute(frame, ax, ay);
      if (attr.flash) ensureSpectrumFlashTimer();
      return attr;
    })
  ));
}

function frameBitmapRows(frame, width, visibleHeight) {
  return Array.from({ length: visibleHeight }, (_, y) => {
    const row = frame.rows && frame.rows[y] ? frame.rows[y] : "";
    return Array.from({ length: width }, (_, x) => row[x] === "1");
  });
}

function ensureSpectrumFramebuffer(width, height) {
  if (!spectrumBitmapRows || spectrumBitmapRows.length !== height || (spectrumBitmapRows[0] && spectrumBitmapRows[0].length) !== width) {
    spectrumBitmapRows = Array.from({ length: height }, () => Array(width).fill(false));
  }
  const rows = Math.ceil(height / 8);
  const cols = Math.ceil(width / 8);
  if (!spectrumFrameAttributes || spectrumFrameAttributes.length !== rows || (spectrumFrameAttributes[0] && spectrumFrameAttributes[0].length) !== cols) {
    spectrumFrameAttributes = Array.from({ length: rows }, () => Array.from({ length: cols }, () => defaultFrameAttribute()));
  }
}

function frameCellHasInk(frame, ax, ay, width, visibleHeight) {
  return frameCellHasRowBit(frame.overlay_rows || frame.rows, ax, ay, width, visibleHeight);
}

function frameCellHasClear(frame, ax, ay, width, visibleHeight) {
  return frameCellHasRowBit(frame.clear_rows, ax, ay, width, visibleHeight);
}

function frameCellHasToggle(frame, ax, ay, width, visibleHeight) {
  return frameCellHasRowBit(frame.toggle_rows, ax, ay, width, visibleHeight);
}

function frameCellHasRowBit(rows, ax, ay, width, visibleHeight) {
  const yStart = ay * 8;
  const yEnd = Math.min(visibleHeight, yStart + 8);
  const xStart = ax * 8;
  const xEnd = Math.min(width, xStart + 8);
  for (let y = yStart; y < yEnd; y += 1) {
    const row = rows && rows[y] ? rows[y] : "";
    for (let x = xStart; x < xEnd; x += 1) {
      if (row[x] === "1") return true;
    }
  }
  return false;
}

function writeImagePixel(image, width, x, y, color) {
  const offset = (y * width + x) * 4;
  image.data[offset] = color[0];
  image.data[offset + 1] = color[1];
  image.data[offset + 2] = color[2];
  image.data[offset + 3] = 255;
}

function redrawSpectrumCell(image, width, visibleHeight, ax, ay, attr) {
  const yStart = ay * 8;
  const yEnd = Math.min(visibleHeight, yStart + 8);
  const xStart = ax * 8;
  const xEnd = Math.min(width, xStart + 8);
  for (let y = yStart; y < yEnd; y += 1) {
    for (let x = xStart; x < xEnd; x += 1) {
      writeImagePixel(image, width, x, y, spectrumPixelColor(attr, spectrumBitmapRows[y][x]));
    }
  }
}

function spectrumPixelColor(attr, on) {
  const palette = attr.bright ? brightSpectrumColorByCode : spectrumColorByCode;
  const effectiveOn = attr.flash && spectrumFlashPhase ? !on : on;
  const code = Number(effectiveOn ? attr.ink : attr.paper) & 7;
  return hexToRgb(palette[code] || (on ? "#000000" : "#ffffff"));
}

function applyScreenAttributes(event) {
  const palette = event.bright ? brightSpectrumColors : spectrumColors;
  if (event.ink) currentScreenStyle.ink = event.ink;
  if (event.paper) currentScreenStyle.paper = event.paper;
  if (event.bright != null) currentScreenStyle.bright = event.bright === true;
  if (event.flash != null) currentScreenStyle.flash = event.flash === true;
  if (event.ink && palette[event.ink]) {
    document.documentElement.style.setProperty("--ink", palette[event.ink]);
  }
  if (event.paper && spectrumColors[event.paper]) {
    document.documentElement.style.setProperty("--paper", spectrumColors[event.paper]);
  }
}

function hexToRgb(hex) {
  const value = hex.replace("#", "");
  return [
    parseInt(value.slice(0, 2), 16),
    parseInt(value.slice(2, 4), 16),
    parseInt(value.slice(4, 6), 16),
  ];
}

function clearInputTimeout() {
  if (!inputTimeoutId) return;

  window.clearTimeout(inputTimeoutId);
  inputTimeoutId = null;
}

function setInputMode(mode, prompt = "> ", timeoutMs = null, event = {}) {
  clearInputTimeout();
  inputMode = mode;
  commandForm.classList.toggle("waiting-key", mode === "key");
  lineInputOrigin = null;
  mirroredInputLength = 0;
  lineInputStyle = normalizeInputStyle(event.input_style);
  lineInputCursorStyle = normalizeInputStyle(event.cursor_style);
  lineInputCursorGlyph = event.cursor_glyph == null ? null : Number(event.cursor_glyph);
  applyInputPromptStyle(lineInputStyle);

  if (mode === "key") {
    commandInput.value = "";
    commandInput.readOnly = true;
    commandInput.placeholder = "";
    promptMark.textContent = "";
  } else {
    commandInput.readOnly = false;
    commandInput.placeholder = "";
    appendPromptMessage(prompt);
    promptMark.textContent = ">";
    if (textRenderer === "spectrum") {
      lineInputOrigin = {
        row: event.screen_row == null ? screenCursor.row : Number(event.screen_row),
        col: event.screen_col == null ? screenCursor.col : Number(event.screen_col),
      };
      clearScreenCells(lineInputOrigin.row, lineInputOrigin.col, 32, currentScreenStyle);
      drawMirroredInput("");
    }
    if (Number.isFinite(timeoutMs) && timeoutMs > 0) {
      inputTimeoutId = window.setTimeout(sendTimeout, timeoutMs);
    }
  }

  commandInput.focus();
  updatePcKeyFullLayout();
}

function updatePcKeyFullLayout() {
  const keyOnlyStartupScreen = textRenderer === "pc" &&
    inputMode === "key" &&
    !graphicsPane.hidden &&
    transcript.textContent.trim() === "";
  gameShell.classList.toggle("pc-key-full", keyOnlyStartupScreen);
  requestFitScreen();
}

function normalizeInputStyle(style) {
  if (!style || typeof style !== "object") return null;

  return {
    ink: style.ink || null,
    paper: style.paper || null,
    bright: style.bright === true,
    flash: style.flash === true,
    charset: style.charset == null ? null : Number(style.charset),
  };
}

function applyInputPromptStyle(style) {
  const ink = style && style.ink && spectrumColors[style.ink] ? spectrumColors[style.ink] : spectrumColors.yellow;
  document.documentElement.style.setProperty("--prompt", ink);
}

function setDebugStatus(paused, breakpoint = null, stepping = false) {
  debugPaused = paused === true;
  debugStepping = stepping === true;
  const active = debugPaused || debugStepping;
  debugPauseOverlay.hidden = !active;
  commandInput.disabled = active;

  if (!active) {
    debugPauseText.textContent = "Debugger paused";
    return;
  }

  const process = breakpoint && breakpoint.process != null ? String(breakpoint.process).padStart(3, "0") : "---";
  const block = breakpoint && breakpoint.block != null ? String(breakpoint.block).padStart(3, "0") : "---";
  const condact = breakpoint && breakpoint.condact != null ? String(breakpoint.condact).padStart(3, "0") : "---";
  const label = debugPaused ? "Debugger paused" : "Debugger stepping";
  debugPauseText.textContent = `${label} P${process} B${block} C${condact}`;
}

function appendPromptMessage(prompt) {
  const rawText = (prompt || "").replace(/\r/g, "");
  const comparableText = rawText.trim();
  if (!comparableText || comparableText === ">") return;

  appendTranscript(rawText.trimEnd());
}

function delay(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function enqueueEnvelope(envelope) {
  eventQueue = eventQueue
    .catch(() => {})
    .then(() => handleEnvelope(envelope));
  return eventQueue;
}

async function handleEvent(event) {
  switch (event.type) {
    case "session.ready":
      sessionId = event.session_id;
      debugEnabled = event.debug === true;
      remoteDebugEnabled = event.remote_debug === true;
      textRenderer = event.text_renderer === "spectrum" ? "spectrum" : "pc";
      graphicsMode = event.graphics_mode || "original";
      gameShell.dataset.textRenderer = textRenderer;
      gameShell.dataset.graphicsMode = graphicsMode;
      applyFontSize(event.font_size);
      startDebugPolling();
      if (debugEnabled) appendTranscript(`[debug] session=${event.session_id} game=${event.game}`, "debug-line");
      break;
    case "text.append":
      appendTranscript(
        event.text,
        isPromptEcho(event.text) ? "prompt-echo" : "",
        transcriptLineOpen || event.newline === false,
        event.newline === false,
      );
      break;
    case "text.clear":
      transcript.textContent = "";
      transcriptCharsetId = activeCharsetId;
      transcriptLineOpen = false;
      spectrumTextDrawnSinceFrame = false;
      updatePcKeyFullLayout();
      break;
    case "screen.clear":
      resetBlankScreen();
      currentScreenFullFrame = false;
      screenTextCharsetId = activeCharsetId;
      positionedScreenTextCharsetId = activeCharsetId;
      screenText.textContent = "";
      spectrumTextDrawnSinceFrame = false;
      graphicsPane.hidden = true;
      gameShell.classList.add("no-graphics");
      gameShell.classList.remove("screen-full");
      gameShell.classList.remove("pc-key-full");
      break;
    case "screen.frame":
      drawFrame(event);
      break;
    case "screen.extern":
      if (debugEnabled) appendTranscript(`[debug] extern parameter=${event.parameter}`, "debug-line");
      break;
    case "screen.text":
      appendScreenText(event);
      break;
    case "screen.scroll":
      scrollScreenText(Number(event.lines || 1));
      break;
    case "screen.pause":
      await waitForPaint();
      await delay(Math.max(0, Number(event.duration_ms || 0)));
      break;
    case "screen.attributes":
      applyScreenAttributes(event);
      if (debugEnabled) {
        appendTranscript(
          `[debug] attributes ink=${event.ink} paper=${event.paper} bright=${event.bright} flash=${event.flash}`,
          "debug-line",
        );
      }
      break;
    case "screen.charset":
      applyScreenCharset(event);
      if (debugEnabled) {
        appendTranscript(
          `[debug] charset active=${event.active} count=${event.charsets && event.charsets.count}`,
          "debug-line",
        );
      }
      break;
    case "screen.charset.select":
      selectScreenCharset(event);
      if (debugEnabled) appendTranscript(`[debug] charset active=${event.active}`, "debug-line");
      break;
    case "input.request":
      setInputMode(event.mode || "line", event.prompt || "> ", event.timeout_ms, event);
      break;
    case "debug.message":
      if (debugEnabled) appendTranscript(`[${event.level}] ${event.message}`, "debug-line");
      break;
    case "debug.status":
      setDebugStatus(event.paused, event.breakpoint || null, event.stepping === true);
      break;
    case "error":
      appendTranscript(`Error: ${event.message}`, "error-line");
      break;
    default:
      if (debugEnabled) appendTranscript(`[debug] ${JSON.stringify(event)}`, "debug-line");
  }
}

function applyFontSize(fontSize) {
  if (fontSize == null) return;

  const size = Number(fontSize);
  if (!Number.isFinite(size) || size <= 0) return;

  document.documentElement.style.setProperty("--text-font-size", `${size}px`);
}

function isPromptEcho(text) {
  return String(text || "").replace(/\{[^}]+\}/g, "").startsWith("> ");
}

async function handleEnvelope(envelope) {
  for (const event of envelope.events || []) {
    await handleEvent(event);
  }
  if (envelope.snapshot && envelope.snapshot.debug_paused != null) {
    setDebugStatus(
      envelope.snapshot.debug_paused === true,
      envelope.snapshot.debug_breakpoint || null,
      envelope.snapshot.debug_stepping === true,
    );
  }
  if (debugEnabled && envelope.snapshot) {
    appendTranscript(
      `[debug] loc=${envelope.snapshot.location} turns=${envelope.snapshot.turns} running=${envelope.snapshot.running}`,
      "debug-line",
    );
  }
}

function startDebugPolling() {
  if (!remoteDebugEnabled || debugPollId != null || !sessionId) return;

  debugPollId = window.setInterval(async () => {
    try {
      const envelope = await getJson(`/api/sessions/${sessionId}/debug-state`);
      await enqueueEnvelope(envelope);
    } catch (_error) {
      setDebugStatus(false);
    }
  }, 750);
}

async function sendKey(key) {
  if (!sessionId || pendingKey) return;
  if (debugPaused || debugStepping) return;

  pendingKey = true;
  try {
    const envelope = await postJson(`/api/sessions/${sessionId}/key`, { key });
    await enqueueEnvelope(envelope);
  } catch (error) {
    handleTransportError(error);
  } finally {
    pendingKey = false;
  }
}

async function sendTimeout() {
  inputTimeoutId = null;
  if (!sessionId || inputMode !== "line") return;
  if (debugPaused || debugStepping) return;
  if (commandInput.value.length > 0) return;

  try {
    const envelope = await postJson(`/api/sessions/${sessionId}/timeout`, {});
    await enqueueEnvelope(envelope);
  } catch (error) {
    handleTransportError(error);
  }
}

async function boot() {
  const session = await postJson("/api/sessions", {});
  await enqueueEnvelope(session);
}

commandForm.addEventListener("submit", (event) => {
  event.preventDefault();
  if (inputMode === "key") return;
  if (debugPaused || debugStepping) return;

  const value = commandInput.value.trim();
  if (!value) return;
  clearInputTimeout();
  commitMirroredInput();

  commandInput.value = "";
  if (!sessionId) {
    appendTranscript("La sesion todavia no esta preparada.", "error-line");
    return;
  }

  postJson(`/api/sessions/${sessionId}/input`, { text: value })
    .then(enqueueEnvelope)
    .catch(handleTransportError);
});

commandInput.addEventListener("input", () => {
  if (inputMode !== "line") return;

  drawMirroredInput(commandInput.value);
});

document.addEventListener("keydown", (event) => {
  if (inputMode !== "key") return;

  event.preventDefault();
  sendKey(event.key);
});

document.addEventListener("click", () => {
  commandInput.focus();
});

if ("ResizeObserver" in window) {
  const resizeObserver = new ResizeObserver(requestFitScreen);
  resizeObserver.observe(gameShell);
  resizeObserver.observe(graphicsPane);
} else {
  window.addEventListener("resize", requestFitScreen);
}

boot().catch((error) => appendTranscript(`Boot error: ${error.message}`, "error-line"));
