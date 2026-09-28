"use strict";
// The Settings window. It shows the settings in effect and changes one at a time through the
// app's commands (src/settings/window.rs), which save it, apply it to dictation and send every
// window the settings now in effect ("settings"), so a change from the tray shows here too.
// How dictation stands comes as "status".

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

/** The command-line option that sets each setting for a run. */
const OPTION_FOR = {
  dictationEnabled: null,
  dictationHotkey: "--key",
  handsFreeEnabled: "--no-hands-free",
  cleanupLevel: "--cleanup",
  sttModel: "--model",
  sttDevice: "--device",
};

const DEVICE_NAMES = {
  auto: "Auto",
  NPU: "NPU only",
  GPU: "GPU only",
  CPU: "CPU only",
};

const DEVICE_HELP = {
  auto: "The NPU when there is one, and the CPU for what the NPU can’t run.",
  NPU: "Only the NPU; a prompt or reply too long for it still goes to the CPU.",
  GPU: "Only the integrated GPU.",
  CPU: "Only the CPU.",
};

/** Keys as KeyboardEvent.code names them, as linux/input-event-codes.h does. */
const KEY_NAMES = (() => {
  const names = {
    Backquote: "KEY_GRAVE", Minus: "KEY_MINUS", Equal: "KEY_EQUAL", Backspace: "KEY_BACKSPACE",
    Tab: "KEY_TAB", BracketLeft: "KEY_LEFTBRACE", BracketRight: "KEY_RIGHTBRACE",
    Backslash: "KEY_BACKSLASH", CapsLock: "KEY_CAPSLOCK", Semicolon: "KEY_SEMICOLON",
    Quote: "KEY_APOSTROPHE", Enter: "KEY_ENTER", Comma: "KEY_COMMA", Period: "KEY_DOT",
    Slash: "KEY_SLASH", Space: "KEY_SPACE", IntlBackslash: "KEY_102ND", IntlRo: "KEY_RO",
    IntlYen: "KEY_YEN", ShiftLeft: "KEY_LEFTSHIFT", ShiftRight: "KEY_RIGHTSHIFT",
    ControlLeft: "KEY_LEFTCTRL", ControlRight: "KEY_RIGHTCTRL", AltLeft: "KEY_LEFTALT",
    AltRight: "KEY_RIGHTALT", MetaLeft: "KEY_LEFTMETA", MetaRight: "KEY_RIGHTMETA",
    ContextMenu: "KEY_COMPOSE", PrintScreen: "KEY_SYSRQ", ScrollLock: "KEY_SCROLLLOCK",
    Pause: "KEY_PAUSE", Insert: "KEY_INSERT", Home: "KEY_HOME", PageUp: "KEY_PAGEUP",
    Delete: "KEY_DELETE", End: "KEY_END", PageDown: "KEY_PAGEDOWN", ArrowRight: "KEY_RIGHT",
    ArrowLeft: "KEY_LEFT", ArrowDown: "KEY_DOWN", ArrowUp: "KEY_UP", NumLock: "KEY_NUMLOCK",
    NumpadDivide: "KEY_KPSLASH", NumpadMultiply: "KEY_KPASTERISK", NumpadSubtract: "KEY_KPMINUS",
    NumpadAdd: "KEY_KPPLUS", NumpadEnter: "KEY_KPENTER", NumpadDecimal: "KEY_KPDOT",
    NumpadEqual: "KEY_KPEQUAL", NumpadComma: "KEY_KPCOMMA", AudioVolumeMute: "KEY_MUTE",
    AudioVolumeDown: "KEY_VOLUMEDOWN", AudioVolumeUp: "KEY_VOLUMEUP",
    MediaPlayPause: "KEY_PLAYPAUSE", MediaStop: "KEY_STOPCD", MediaTrackNext: "KEY_NEXTSONG",
    MediaTrackPrevious: "KEY_PREVIOUSSONG", Help: "KEY_HELP", Lang1: "KEY_HANGEUL",
    Lang2: "KEY_HANJA", KanaMode: "KEY_KATAKANAHIRAGANA", Convert: "KEY_HENKAN",
    NonConvert: "KEY_MUHENKAN",
  };
  for (let letter = 65; letter <= 90; letter += 1) {
    const character = String.fromCharCode(letter);
    names[`Key${character}`] = `KEY_${character}`;
  }
  for (let digit = 0; digit <= 9; digit += 1) {
    names[`Digit${digit}`] = `KEY_${digit}`;
    names[`Numpad${digit}`] = `KEY_KP${digit}`;
  }
  for (let number = 1; number <= 24; number += 1) {
    names[`F${number}`] = `KEY_F${number}`;
  }
  return names;
})();

/**
 * Keys that may be held for a combination: one of these on its own is the hotkey only once it is
 * released without another key. A laptop's Copilot key sends Super, Shift and F23 together, and
 * F23 is the key to keep.
 */
const MODIFIERS = new Set([
  "ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight",
  "AltLeft", "AltRight", "MetaLeft", "MetaRight",
]);

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

let snapshot = null;
let microphones = null;
let models = null;
let status = null;
/**
 * The shortcut being recorded: the modifier pressed first, if any, and whether a key has been
 * chosen, after which the keys still being released mean nothing.
 */
let recording = null;
let toastTimer = null;

// Changing settings

async function change(changes) {
  try {
    render(await invoke("change_settings", { changes }));
    return true;
  } catch (error) {
    showToast(`That couldn’t be changed: ${error}`);
    if (snapshot) {
      render(snapshot);
    }
    return false;
  }
}

function showToast(message) {
  const toast = $("#toast");
  toast.textContent = message;
  toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    toast.hidden = true;
  }, 6000);
}

// Showing them

function render(next) {
  snapshot = next;
  const { settings } = next;
  document.documentElement.dataset.theme = next.theme;

  for (const input of $$("input.switch[data-setting]")) {
    input.checked = Boolean(settings[input.dataset.setting]);
  }
  for (const input of $$(".number input[data-setting]")) {
    // Someone typing keeps what they type until they're done.
    if (document.activeElement !== input) {
      input.value = settings[input.dataset.setting];
    }
  }
  renderCleanup(next);
  if (!recording) {
    $("#hotkey").textContent = next.hotkeyName;
  }
  renderOverrides(next);
  renderMicrophones();
  renderModels();
  renderDevices();
}

function renderCleanup(next) {
  const list = $("#cleanup");
  if (!list.childElementCount) {
    for (const level of next.cleanupLevels) {
      const row = document.createElement("label");
      row.className = "row choice";
      const radio = document.createElement("input");
      radio.type = "radio";
      radio.name = "cleanupLevel";
      radio.value = level.id;
      radio.addEventListener("change", () => change({ cleanupLevel: level.id }));
      const text = document.createElement("span");
      text.className = "text";
      const title = document.createElement("span");
      title.className = "title";
      title.textContent = level.id === next.defaults.cleanupLevel ? `${level.name} (default)` : level.name;
      const summary = document.createElement("span");
      summary.className = "subtitle";
      summary.textContent = level.summary;
      text.append(title, summary);
      row.append(radio, text);
      list.append(row);
    }
  }
  for (const radio of $$('#cleanup input[name="cleanupLevel"]')) {
    radio.checked = radio.value === next.settings.cleanupLevel;
  }
}

function renderOverrides(next) {
  for (const note of $$("[data-override]")) {
    const key = note.dataset.override;
    const option = OPTION_FOR[key];
    const overridden = next.overridden.includes(key);
    note.hidden = !overridden || !option;
    if (overridden && option) {
      note.textContent = `Set by ${option} when Live Transcribe started. A change here applies now; the next start with ${option} sets it again.`;
    }
  }
}

function option(value, label) {
  const element = document.createElement("option");
  element.value = value;
  element.textContent = label;
  return element;
}

function renderMicrophones() {
  if (!snapshot) {
    return;
  }
  const select = $("#microphone");
  const chosen = snapshot.settings.inputDeviceId ?? "";
  const list = microphones?.microphones ?? [];
  const systemDefault = list.find((microphone) => microphone.id === microphones?.defaultId);
  const options = [option("", "System default")];
  for (const microphone of list) {
    options.push(option(microphone.id, microphone.name));
  }
  const missing = chosen && microphones && !list.some((microphone) => microphone.id === chosen);
  if (chosen && !list.some((microphone) => microphone.id === chosen)) {
    options.push(option(chosen, missing ? `${shortDevice(chosen)} (not connected)` : shortDevice(chosen)));
  }
  select.replaceChildren(...options);
  select.value = chosen;

  const defaultName = systemDefault ? systemDefault.name : "the system default";
  let help;
  if (!microphones) {
    help = "";
  } else if (!chosen) {
    help = systemDefault ? `Now ${systemDefault.name}.` : "No microphone is connected.";
  } else if (missing) {
    help = `Not connected, so dictation records from ${defaultName} until it is.`;
  } else {
    help = `If it isn’t connected, dictation records from ${defaultName}.`;
  }
  $("#microphone-help").textContent = help;
}

/** A device id without its audio system, trimmed to fit. */
function shortDevice(id) {
  const name = id.replace(/^[a-z]+:/, "");
  return name.length > 40 ? `${name.slice(0, 39)}…` : name;
}

function renderModels() {
  if (!snapshot) {
    return;
  }
  const select = $("#model");
  const chosen = snapshot.settings.sttModel ?? "";
  const list = models?.models ?? [];
  const defaultModel = list.find((model) => model.name === snapshot.defaultModel);
  const options = [option("", `${snapshot.defaultModel} (default)`)];
  for (const model of list) {
    if (model.name !== snapshot.defaultModel) {
      options.push(option(model.name, model.problem ? `${model.name} (can’t run)` : model.name));
    }
  }
  if (chosen && !list.some((model) => model.name === chosen)) {
    options.push(option(chosen, `${chosen} (not found)`));
  }
  select.replaceChildren(...options);
  select.value = chosen;

  const shown = chosen ? list.find((model) => model.name === chosen) : defaultModel;
  let source;
  if (!models) {
    source = "";
  } else if (!shown) {
    source = chosen
      ? "Not in the models folder: convert it with the setup kit, or choose another."
      : "Not converted yet: the setup kit’s 07-export-model.sh converts it.";
  } else if (shown.problem) {
    source = `${shown.source || shown.name}: this version can’t run it (${shown.problem}).`;
  } else {
    source = shown.source ? `Converted from ${shown.source}.` : "";
  }
  $("#model-source").textContent = source;
  if (models) {
    $("#models-folder").firstChild.textContent = `The setup kit converts models into ${models.folder} (`;
  }
}

function renderDevices() {
  const select = $("#device");
  if (!select.childElementCount) {
    select.replaceChildren(...snapshot.devices.map((device) => option(device, DEVICE_NAMES[device] ?? device)));
  }
  select.value = snapshot.settings.sttDevice;
  $("#device-help").textContent = DEVICE_HELP[snapshot.settings.sttDevice] ?? "";
}

function renderStatus(next) {
  status = next;
  const row = $("#model-status");
  const state = next?.model ?? "loading";
  row.dataset.state = state;
  $("#model-state").textContent = {
    idle: "The speech model loads once dictation can start",
    downloading: "Downloading the speech model…",
    loading: "Loading the speech model…",
    ready: "The speech model is ready",
    failed: "The speech model couldn’t load",
  }[state];
  $("#model-detail").textContent = next?.detail ? capitalise(next.detail) : "";
  $("#reload-model").hidden = state !== "failed";
  const blocker = next?.blocker;
  $("#blocker").hidden = !blocker;
  $("#blocker-title").textContent = blocker?.title ?? "";
  $("#blocker-detail").textContent = blocker?.detail ?? "";
}

function capitalise(text) {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

// Loading what the choices are

async function loadMicrophones() {
  try {
    microphones = await invoke("microphones");
  } catch (error) {
    microphones = null;
    $("#microphone-help").textContent = `The microphones couldn’t be listed: ${error}`;
  }
  renderMicrophones();
}

async function loadModels() {
  try {
    models = await invoke("models");
  } catch (error) {
    models = null;
    $("#model-source").textContent = `The models couldn’t be listed: ${error}`;
  }
  renderModels();
}

// Recording the hotkey

async function startRecording() {
  if (recording) {
    return;
  }
  recording = { modifier: null, chosen: false };
  const button = $("#hotkey");
  button.classList.add("recording");
  button.textContent = "Press a key…";
  $("#hotkey-problem").hidden = true;
  // While this listens, the hotkey and Esc mustn't dictate.
  await invoke("pause_hotkey", { paused: true }).catch(() => {});
}

async function stopRecording() {
  if (!recording) {
    return;
  }
  recording = null;
  const button = $("#hotkey");
  button.classList.remove("recording");
  if (snapshot) {
    button.textContent = snapshot.hotkeyName;
  }
  await invoke("pause_hotkey", { paused: false }).catch(() => {});
}

async function record(code) {
  recording.chosen = true;
  const name = KEY_NAMES[code];
  if (!name) {
    showProblem(`That key (${code || "unknown"}) can’t be recorded here. Start Live Transcribe with --key and its name, which livetranscribe keys prints.`);
  } else {
    try {
      const key = await invoke("describe_hotkey", { name });
      await change({ dictationHotkey: key.name });
    } catch (error) {
      showProblem(`${capitalise(String(error))}.`);
    }
  }
  // The new hotkey is set before the old one's pause ends.
  await stopRecording();
}

function showProblem(message) {
  const problem = $("#hotkey-problem");
  problem.textContent = message;
  problem.hidden = false;
}

function onKeyDown(event) {
  if (!recording) {
    return;
  }
  event.preventDefault();
  event.stopPropagation();
  if (event.repeat || recording.chosen) {
    return;
  }
  if (event.code === "Escape") {
    stopRecording();
    return;
  }
  if (MODIFIERS.has(event.code)) {
    recording.modifier ??= event.code;
    return;
  }
  record(event.code);
}

function onKeyUp(event) {
  if (!recording) {
    return;
  }
  event.preventDefault();
  if (!recording.chosen && recording.modifier === event.code) {
    record(event.code);
  }
}

// Tabs

function selectTab(tab, { focus = false } = {}) {
  for (const other of $$(".tab")) {
    const selected = other === tab;
    other.setAttribute("aria-selected", String(selected));
    other.tabIndex = selected ? 0 : -1;
    $(`#${other.getAttribute("aria-controls")}`).hidden = !selected;
  }
  if (focus) {
    tab.focus();
  }
}

// Wiring

function bind() {
  for (const tab of $$(".tab")) {
    tab.addEventListener("click", () => selectTab(tab));
    tab.addEventListener("keydown", (event) => {
      const tabs = $$(".tab");
      const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
      if (step) {
        selectTab(tabs[(tabs.indexOf(tab) + step + tabs.length) % tabs.length], { focus: true });
      }
    });
  }
  for (const input of $$("input.switch[data-setting]")) {
    input.addEventListener("change", () => change({ [input.dataset.setting]: input.checked }));
  }
  for (const input of $$(".number input[data-setting]")) {
    input.addEventListener("change", () => {
      const value = Number(input.value);
      if (input.value === "" || !Number.isFinite(value)) {
        render(snapshot);
        return;
      }
      change({ [input.dataset.setting]: value });
    });
  }
  for (const select of [$("#microphone"), $("#model"), $("#device")]) {
    select.addEventListener("change", () => change({ [select.dataset.setting]: select.value || null }));
  }
  $("#hotkey").addEventListener("click", startRecording);
  $("#hotkey").addEventListener("blur", stopRecording);
  window.addEventListener("keydown", onKeyDown, true);
  window.addEventListener("keyup", onKeyUp, true);
  window.addEventListener("blur", stopRecording);
  // A microphone plugged in, or a model converted, while the window was in the background.
  window.addEventListener("focus", () => {
    loadMicrophones();
    loadModels();
  });
  $("#reload-model").addEventListener("click", () => invoke("reload_model").catch((error) => showToast(String(error))));
  $("#restore-advanced").addEventListener("click", () => {
    const changes = Object.fromEntries(snapshot.advancedKeys.map((key) => [key, snapshot.defaults[key]]));
    change(changes);
  });
}

async function start() {
  bind();
  await listen("settings", (event) => render(event.payload));
  await listen("status", (event) => renderStatus(event.payload));
  render(await invoke("settings_snapshot"));
  renderStatus(await invoke("dictation_status"));
  await Promise.all([loadMicrophones(), loadModels()]);
}

start().catch((error) => showToast(`Settings couldn’t load: ${error}`));
