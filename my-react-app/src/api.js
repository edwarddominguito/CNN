export const MAX_IMAGE_BYTES = 15 * 1024 * 1024;
const MAX_IMAGE_PIXELS = 25000000;
const API_CONFIGURATION_ERROR = "The app is not connected to its server. Please contact the app administrator.";

// Inspect compressed headers before the browser allocates a full preview.
export function imageDimensions(buffer) {
  const view = new DataView(buffer);
  const bytes = new Uint8Array(buffer);
  const uint24 = (offset) => bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
  let dimensions;
  if (bytes.length >= 24 && view.getUint32(0) === 0x89504e47
    && view.getUint32(4) === 0x0d0a1a0a && view.getUint32(12) === 0x49484452) {
    dimensions = [view.getUint32(16), view.getUint32(20)];
    let offset = 8;
    while (offset + 12 <= bytes.length) {
      const length = view.getUint32(offset);
      if (offset + 12 + length > bytes.length) break;
      if (view.getUint32(offset + 4) === 0x6163544c) {
        throw new Error("Animated images are not supported. Please select a single still image.");
      }
      offset += 12 + length;
    }
  } else if (bytes.length >= 4 && view.getUint16(0) === 0xffd8) {
    let offset = 2;
    while (offset + 3 < bytes.length) {
      if (bytes[offset++] !== 0xff) break;
      while (bytes[offset] === 0xff) offset++;
      const marker = bytes[offset++];
      if (marker === 0xd9 || marker === 0xda) break;
      if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) continue;
      if (offset + 2 > bytes.length) break;
      const length = view.getUint16(offset);
      if (length < 2 || offset + length > bytes.length) break;
      if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker)) {
        if (length >= 7) dimensions = [view.getUint16(offset + 5), view.getUint16(offset + 3)];
        break;
      }
      offset += length;
    }
  } else if (bytes.length >= 20 && view.getUint32(0) === 0x52494646 && view.getUint32(8) === 0x57454250) {
    let offset = 12;
    while (offset + 8 <= bytes.length) {
      const tag = view.getUint32(offset);
      const size = view.getUint32(offset + 4, true);
      const start = offset + 8;
      if (start + size > bytes.length) break;
      if (tag === 0x56503858 && size >= 10) { // VP8X
        if (bytes[start] & 0x02) {
          throw new Error("Animated images are not supported. Please select a single still image.");
        }
        dimensions = [uint24(start + 4) + 1, uint24(start + 7) + 1];
      } else if (tag === 0x56503820 && size >= 10 && uint24(start + 3) === 0x2a019d) { // VP8
        dimensions = [view.getUint16(start + 6, true) & 0x3fff, view.getUint16(start + 8, true) & 0x3fff];
      } else if (tag === 0x5650384c && size >= 5 && bytes[start] === 0x2f) { // VP8L
        const bits = view.getUint32(start + 1, true);
        dimensions = [(bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1];
      }
      if (dimensions) break;
      offset = start + size + (size % 2);
    }
  }
  if (!dimensions || dimensions.some((value) => value < 1)) {
    throw new Error("Unable to read this image. Please select a valid JPG, PNG, or WebP image.");
  }
  if (dimensions[0] * dimensions[1] > MAX_IMAGE_PIXELS) {
    throw new Error("This image has too many pixels. Please use an image with at most 25 million pixels.");
  }
  return dimensions;
}

export function validateImageFile(file) {
  if (!file || file.size === 0) return "This file is empty. Please select an image.";
  if (file.size > MAX_IMAGE_BYTES) return "This image is too large. Please use an image under 15 MB.";
  if (!/\.(jpe?g|png|webp)$/i.test(file.name)) {
    return "Unsupported image format. Please use a JPG, PNG, or WebP image.";
  }
  return null;
}

// An empty setting uses the same origin as the app, including Railway's HTTPS.
export function apiBaseUrl(value = import.meta.env?.VITE_API_URL ?? "", protocol = globalThis.location?.protocol) {
  const trimmed = value.trim().replace(/\/+$/, "");
  if (!trimmed) return "";
  let url;
  try {
    url = new URL(trimmed);
  } catch {
    throw new Error(API_CONFIGURATION_ERROR);
  }
  if (!["https:", "http:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw new Error(API_CONFIGURATION_ERROR);
  }
  if (protocol === "https:" && url.protocol !== "https:") {
    throw new Error(API_CONFIGURATION_ERROR);
  }
  return trimmed;
}

function serverMessage(data, status) {
  const detail = data?.detail ?? data?.error;
  if (typeof detail === "string" && detail.trim()) return detail;
  if (Array.isArray(detail)) {
    const messages = detail.map((item) => item?.msg).filter((message) => typeof message === "string");
    if (messages.length) return messages.join(" ");
  }
  return `Server error (${status}). Please try again.`;
}

export async function predictImage(file, {
  fetchImpl = globalThis.fetch,
  baseUrl = apiBaseUrl(),
  signal,
  timeoutMs = 120000,
} = {}) {
  const invalid = validateImageFile(file);
  if (invalid) throw new Error(invalid);
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener("abort", abort, { once: true });
  if (signal?.aborted) controller.abort();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);

  try {
    const formData = new FormData();
    formData.append("file", file, file.name);
    const response = await fetchImpl(`${baseUrl}/predict`, {
      method: "POST", body: formData, signal: controller.signal,
    });
    const data = await response.json().catch(() => null);
    if (!response.ok) throw new Error(serverMessage(data, response.status));
    if (data?.error) throw new Error(serverMessage(data, response.status));
    const confidence = typeof data?.confidence === "number"
      ? data.confidence
      : typeof data?.confidence === "string" && data.confidence.trim()
        ? Number(data.confidence) : NaN;
    if (typeof data?.predicted_grade !== "string" || !data.predicted_grade.trim()
      || !Number.isFinite(confidence) || confidence < 0 || confidence > 100) {
      throw new Error("The server sent an unreadable prediction. Please try again.");
    }
    return {
      predicted_grade: data.predicted_grade,
      confidence,
      note: typeof data.note === "string" ? data.note : null,
      processing_time_ms: typeof data.processing_time_ms === "number" && Number.isFinite(data.processing_time_ms)
        ? data.processing_time_ms : null,
    };
  } catch (error) {
    if (timedOut) throw new Error("The request timed out. Please try again in a moment.", { cause: error });
    if (error instanceof TypeError) {
      throw new Error("Could not reach the server. Please check your connection and try again.", { cause: error });
    }
    throw error;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", abort);
  }
}
