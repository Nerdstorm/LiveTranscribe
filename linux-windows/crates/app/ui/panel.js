"use strict";
// The dictation panel's page. It asks the app for its frames once, then paints each on the canvas:
// the frame's width and height in pixels (two little-endian 32-bit numbers), then its pixels, R, G,
// B, A. The canvas has that many pixels, stretched over the window, which is that size in the
// screen's own pixels, so each lands on one.

const { invoke, Channel } = window.__TAURI__.core;

const canvas = document.querySelector("canvas");
const context = canvas.getContext("2d");

const frames = new Channel();
frames.onmessage = (buffer) => {
  const header = new DataView(buffer, 0, 8);
  const width = header.getUint32(0, true);
  const height = header.getUint32(4, true);
  if (width === 0 || height === 0 || buffer.byteLength < 8 + width * height * 4) {
    return;
  }
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }
  const pixels = new Uint8ClampedArray(buffer, 8, width * height * 4);
  context.putImageData(new ImageData(pixels, width, height), 0, 0);
};

invoke("panel_frames", { frames }).catch((error) => console.error("No frames for the panel:", error));
