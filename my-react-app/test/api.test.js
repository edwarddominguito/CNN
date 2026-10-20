import test from "node:test";
import assert from "node:assert/strict";
import { apiBaseUrl, imageDimensions, MAX_IMAGE_BYTES, predictImage, validateImageFile } from "../src/api.js";

const image = new File(["sample"], "rice.jpg", { type: "image/jpeg" });
const reply = (data, status = 200) => new Response(JSON.stringify(data), { status });

test("preview headers reject compressed oversized images before decoding", () => {
  const png = new ArrayBuffer(24);
  const view = new DataView(png);
  view.setUint32(0, 0x89504e47);
  view.setUint32(4, 0x0d0a1a0a);
  view.setUint32(12, 0x49484452);
  view.setUint32(16, 5000);
  view.setUint32(20, 5000);
  assert.deepEqual(imageDimensions(png), [5000, 5000]);
  view.setUint32(16, 5001);
  assert.throws(() => imageDimensions(png), /25 million/);
  for (const bytes of [[], [1, 2, 3], [0xff, 0xd8, 0xff, 0xe1, 0, 0]]) {
    assert.throws(() => imageDimensions(new Uint8Array(bytes).buffer), /Unable to read/);
  }
});

test("JPEG and WebP preview dimensions are read without rasterizing", () => {
  assert.deepEqual(imageDimensions(new Uint8Array([
    0xff, 0xd8, 0xff, 0xc0, 0, 8, 8, 0, 32, 0, 64, 1,
  ]).buffer), [64, 32]);
  for (const type of ["VP8X", "VP8 ", "VP8L"]) {
    const webp = new Uint8Array(30);
    const view = new DataView(webp.buffer);
    webp.set(new TextEncoder().encode('RIFF'), 0);
    webp.set(new TextEncoder().encode('WEBP'), 8);
    webp.set(new TextEncoder().encode(type), 12);
    view.setUint32(16, 10, true);
    if (type === "VP8X") {
      webp[24] = 63;
      webp[27] = 31;
    } else if (type === "VP8 ") {
      webp.set([0x9d, 0x01, 0x2a], 23);
      view.setUint16(26, 64, true);
      view.setUint16(28, 32, true);
    } else {
      webp[20] = 0x2f;
      view.setUint32(21, (31 << 14) | 63, true);
    }
    assert.deepEqual(imageDimensions(webp.buffer), [64, 32]);
  }
});

test("animated PNG and WebP files are rejected before preview", () => {
  const png = new ArrayBuffer(53);
  const view = new DataView(png);
  view.setUint32(0, 0x89504e47);
  view.setUint32(4, 0x0d0a1a0a);
  view.setUint32(8, 13);
  view.setUint32(12, 0x49484452);
  view.setUint32(16, 64);
  view.setUint32(20, 32);
  view.setUint32(33, 8);
  view.setUint32(37, 0x6163544c);
  assert.throws(() => imageDimensions(png), /Animated/);
  const webp = new Uint8Array(30);
  const webpView = new DataView(webp.buffer);
  webp.set(new TextEncoder().encode('RIFF'), 0);
  webp.set(new TextEncoder().encode('WEBP'), 8);
  webp.set(new TextEncoder().encode('VP8X'), 12);
  webpView.setUint32(16, 10, true);
  webp[20] = 2;
  assert.throws(() => imageDimensions(webp.buffer), /Animated/);
});

test("same-origin and configured HTTPS deployments resolve without localhost", () => {
  assert.equal(apiBaseUrl("", "https:"), "");
  assert.equal(apiBaseUrl(" https://rice.up.railway.app/ ", "https:"), "https://rice.up.railway.app");
  assert.throws(() => apiBaseUrl("http://localhost:8000", "https:"), /not connected/);
  for (const value of ["oops", "file:///tmp", "https://user:secret@rice.test", "https://rice.test?token=1"]) {
    assert.throws(() => apiBaseUrl(value));
  }
});

test("invalid and oversized files are rejected before uploading", async () => {
  assert.match(validateImageFile({ name: "empty.jpg", size: 0 }), /empty/);
  assert.match(validateImageFile({ name: "huge.jpg", size: MAX_IMAGE_BYTES + 1 }), /large/);
  assert.match(validateImageFile({ name: "rice.heic", size: 42 }), /Unsupported/);
  await assert.rejects(predictImage(new File([], "rice.jpg")), /empty/);
});

test("a real prediction uploads multipart and keeps its percentage", async () => {
  const result = await predictImage(image, {
    baseUrl: "https://rice.test",
    fetchImpl: async (url, options) => {
      assert.equal(url, "https://rice.test/predict");
      assert.equal(options.method, "POST");
      assert.equal(options.body.get("file").name, "rice.jpg");
      return reply({ predicted_grade: "Premium", confidence: "98.7", note: { unexpected: true } });
    },
  });
  assert.equal(result.predicted_grade, "Premium");
  assert.equal(result.confidence, 98.7);
  assert.equal(result.note, null);
});

test("proxy errors and structured API errors render as messages", async () => {
  await assert.rejects(predictImage(image, {
    fetchImpl: async () => new Response("<h1>Unavailable</h1>", { status: 503 }),
  }), /503/);
  await assert.rejects(predictImage(image, {
    fetchImpl: async () => reply({ detail: [{ msg: "Image cannot be decoded" }] }, 422),
  }), /Image cannot be decoded/);
  await assert.rejects(predictImage(image, {
    fetchImpl: async () => { throw new TypeError("Network error"); },
  }), /Could not reach/);
});

test("malformed successful replies never become invented predictions", async () => {
  for (const data of [null, {}, { predicted_grade: {} },
    { predicted_grade: "Premium", confidence: "99oops" },
    { predicted_grade: "Premium", confidence: -1 },
    { predicted_grade: "Premium", confidence: 101 }]) {
    await assert.rejects(predictImage(image, { fetchImpl: async () => reply(data) }), /unreadable/);
  }
});

test("a stalled upload is aborted by its deadline", async () => {
  let aborted = false;
  await assert.rejects(predictImage(image, {
    timeoutMs: 5,
    fetchImpl: async (_url, { signal }) => new Promise((_resolve, reject) => {
      signal.addEventListener("abort", () => {
        aborted = true;
        reject(new DOMException("Aborted", "AbortError"));
      });
    }),
  }), /timed out/);
  assert.equal(aborted, true);
});

test("caller cancellation aborts the fetch", async () => {
  const controller = new AbortController();
  const pending = predictImage(image, {
    signal: controller.signal,
    fetchImpl: async (_url, { signal }) => new Promise((_resolve, reject) => {
      signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")));
    }),
  });
  controller.abort();
  await assert.rejects(pending, { name: "AbortError" });
});
