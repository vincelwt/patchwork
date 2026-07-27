import {
  base64URL,
  challengeText,
  decryptJSON,
  deriveSessionKey,
  encryptJSON,
  pairingCredentials,
  utf8
} from "./relayCrypto.mjs";

const DEVICE_KEY = "pi-desktop-relay-device";
const DB_NAME = "pi-desktop-relay";
const DB_STORE = "keys";
const MAX_FRAME_BYTES = 2 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 30000;
const PROTOCOL_VERSION = 2;

let socket = null;
let sessionKey = null;
let metadata = readMetadata();
let keyBundle = null;
let pairing = { phase: "idle" };
let started = false;
let stopped = false;
let hostOnline = false;
let reconnectDelay = 1000;
let reconnectTimer = null;
let pairingExpiryTimer = null;
let messageChain = Promise.resolve();
let requestChain = Promise.resolve();
const pending = new Map();
const eventListeners = new Set();
const statusListeners = new Set();

export function isRelayMode() {
  return location.hostname === "remote.ai.gloom.sh";
}

export function hasRelayDevice() {
  return !!metadata?.installationId && !!metadata?.deviceId;
}

export function relayPairingState() {
  return pairing;
}

export function startRelay() {
  if (!isRelayMode() || started) return;
  started = true;
  const offer = pairingOfferFromLocation();
  if (offer) {
    beginPairing(offer);
  } else if (hasRelayDevice()) {
    connectExisting();
  } else {
    setPairing({ phase: "unpaired" });
  }
}

export function connectRelayEvents({ onEvent, onStatus }) {
  eventListeners.add(onEvent);
  statusListeners.add(onStatus);
  onStatus(socket?.readyState === WebSocket.OPEN && hostOnline ? "online" : "connecting");
  return {
    close() {
      eventListeners.delete(onEvent);
      statusListeners.delete(onStatus);
    }
  };
}

export async function relayRequest(method, path, body) {
  await waitUntilReady();
  if (!hostOnline) throw new Error("HOST_OFFLINE");
  const id = crypto.randomUUID();
  const result = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pending.delete(id);
      reject(new Error("RELAY_TIMEOUT"));
    }, REQUEST_TIMEOUT_MS);
    pending.set(id, { resolve, reject, timeout });
  });
  const operation = requestChain.then(async () => {
    if (!hostOnline || !sessionKey) throw new Error("RELAY_DISCONNECTED");
    const counter = await nextCounter(metadata.installationId);
    const payload = await encryptJSON({ id, counter, method, path, body: body ?? null }, sessionKey, "device-to-host");
    if (!pending.has(id)) throw new Error("RELAY_TIMEOUT");
    send({ type: "cipher", payload });
  });
  requestChain = operation.catch(() => {});
  try {
    await operation;
  } catch (error) {
    const waiter = pending.get(id);
    if (waiter) {
      pending.delete(id);
      clearTimeout(waiter.timeout);
      waiter.reject(error);
    }
  }
  return result;
}

export async function forgetRelayDevice() {
  stopped = true;
  clearTimeout(reconnectTimer);
  clearTimeout(pairingExpiryTimer);
  socket?.close(1000, "unpaired");
  socket = null;
  rejectPending("UNPAIRED");
  if (metadata?.installationId) await deleteKeys(metadata.installationId).catch(() => {});
  try {
    localStorage.removeItem(DEVICE_KEY);
  } catch {
    /* storage unavailable */
  }
  metadata = null;
  keyBundle = null;
  sessionKey = null;
  hostOnline = false;
  setPairing({ phase: "unpaired" });
}

async function beginPairing(offer) {
  stopped = false;
  setPairing({ phase: "connecting" });
  try {
    const auth = await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign", "verify"]
    );
    const ecdh = await crypto.subtle.generateKey(
      { name: "ECDH", namedCurve: "P-256" },
      false,
      ["deriveBits"]
    );
    const deviceId = base64URL(crypto.getRandomValues(new Uint8Array(24)));
    keyBundle = { authPrivate: auth.privateKey, ecdhPrivate: ecdh.privateKey, counter: 0 };
    const authPublicKey = await crypto.subtle.exportKey("jwk", auth.publicKey);
    const ecdhPublicKey = base64URL(await crypto.subtle.exportKey("raw", ecdh.publicKey));
    metadata = {
      installationId: offer.installationId,
      deviceId,
      name: deviceName(),
      hostPublicKey: offer.hostPublicKey,
      protocolVersion: PROTOCOL_VERSION
    };
    const credentials = await pairingCredentials(
      offer.ticket,
      metadata.installationId,
      deviceId,
      metadata.name,
      ecdhPublicKey,
      authPublicKey
    );
    connect({
      mode: "pair",
      authPublicKey,
      ecdhPublicKey,
      ...credentials
    });
  } catch {
    setPairing({ phase: "error", message: "This browser could not create a secure device key." });
  }
}

async function connectExisting() {
  stopped = false;
  setPairing({ phase: "connecting" });
  try {
    keyBundle = await loadKeys(metadata.installationId);
    if (!keyBundle?.authPrivate || !keyBundle?.ecdhPrivate) {
      await forgetRelayDevice();
      return;
    }
    connect({ mode: "authenticate" });
  } catch {
    setPairing({ phase: "error", message: "This device needs to be paired again." });
  }
}

function connect(context) {
  clearTimeout(reconnectTimer);
  socket?.close();
  sessionKey = null;
  hostOnline = false;
  emitStatus("connecting");
  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const origin = `${protocol}//${location.host}`;
  const ws = new WebSocket(`${origin}/relay/device/${encodeURIComponent(metadata.installationId)}?v=${PROTOCOL_VERSION}`);
  socket = ws;

  ws.onmessage = (event) => {
    const size = typeof event.data === "string" ? new Blob([event.data]).size : event.data?.size || 0;
    if (size > MAX_FRAME_BYTES) return ws.close(1009, "frame too large");
    messageChain = messageChain.then(() => handleMessage(event.data, context)).catch(() => {
      ws.close(1008, "invalid message");
    });
  };
  ws.onclose = (event) => {
    if (socket !== ws) return;
    socket = null;
    hostOnline = false;
    sessionKey = null;
    rejectPending("RELAY_DISCONNECTED");
    emitStatus("offline");
    if (event.code === 1000 && event.reason.includes("newer device connection")) stopped = true;
    if (!stopped && context.mode === "authenticate" && hasRelayDevice()) scheduleReconnect();
    else if (!stopped && context.mode === "pair" && !["paired", "error"].includes(pairing.phase)) {
      setPairing({ phase: "error", message: "Pairing expired or was rejected. Scan a new code." });
    }
  };
  ws.onerror = () => emitStatus("offline");
}

async function handleMessage(raw, context) {
  const text = typeof raw === "string" ? raw : await raw.text();
  const message = JSON.parse(text);
  switch (message.type) {
    case "challenge":
      if (context.mode === "pair") {
        send({
          type: "pair",
          ticketHash: context.ticketHash,
          proof: context.proof,
          deviceId: metadata.deviceId,
          name: metadata.name,
          authPublicKey: context.authPublicKey,
          ecdhPublicKey: context.ecdhPublicKey
        });
      } else {
        const signature = await crypto.subtle.sign(
          { name: "ECDSA", hash: "SHA-256" },
          keyBundle.authPrivate,
          utf8(challengeText(metadata.installationId, metadata.deviceId, message.nonce))
        );
        send({ type: "authenticate", deviceId: metadata.deviceId, signature: base64URL(signature) });
      }
      break;
    case "pairPending": {
      setPairing({ phase: "pending", verificationCode: context.verificationCode });
      clearTimeout(pairingExpiryTimer);
      const remaining = Math.max(0, Number(message.expiresAt) - Date.now());
      pairingExpiryTimer = setTimeout(() => {
        setPairing({ phase: "error", message: "Pairing expired. Scan a new code." });
        socket?.close(1000, "expired");
      }, remaining);
      break;
    }
    case "pairRejected":
      clearTimeout(pairingExpiryTimer);
      setPairing({
        phase: "error",
        message: message.reason === "expiredTicket" ? "Pairing expired. Scan a new code." : "Pairing was denied on the Mac."
      });
      socket?.close(1008, "denied");
      break;
    case "paired":
      if (message.hostPublicKey !== metadata.hostPublicKey) throw new Error("host key mismatch");
      clearTimeout(pairingExpiryTimer);
      await saveKeys(metadata.installationId, keyBundle);
      writeMetadata(metadata);
      sessionKey = await deriveSessionKey(
        keyBundle.ecdhPrivate,
        metadata.hostPublicKey,
        metadata.installationId,
        metadata.deviceId
      );
      setPairing({ phase: "paired" });
      history.replaceState(null, "", "/");
      break;
    case "ready":
      if (!sessionKey) {
        sessionKey = await deriveSessionKey(
          keyBundle.ecdhPrivate,
          metadata.hostPublicKey,
          metadata.installationId,
          metadata.deviceId
        );
      }
      hostOnline = !!message.hostOnline;
      reconnectDelay = 1000;
      setPairing({ phase: "paired" });
      emitStatus(hostOnline ? "online" : "offline");
      if (context.mode === "pair" && !context.pairedNotified) {
        context.pairedNotified = true;
        window.dispatchEvent(new CustomEvent("pi:relay-paired"));
      }
      break;
    case "hostOnline":
      hostOnline = true;
      emitStatus("online");
      break;
    case "hostOffline":
      hostOnline = false;
      rejectPending("HOST_OFFLINE");
      emitStatus("offline");
      break;
    case "cipher":
    case "toDevice":
      await handleCipher(message.payload);
      break;
    case "revoked":
    case "authRejected":
      await forgetRelayDevice();
      break;
    default:
      break;
  }
}

async function handleCipher(payload) {
  if (!sessionKey || !payload) return;
  const message = await decryptJSON(payload, sessionKey, "host-to-device");
  if (message.type === "response") {
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    clearTimeout(waiter.timeout);
    waiter.resolve({ status: message.status, body: message.body || "" });
  } else if (message.type === "event") {
    let data = message.data;
    try {
      data = JSON.parse(message.data);
    } catch {
      /* forward-compatible raw payload */
    }
    for (const listener of eventListeners) listener(message.name, data);
  }
}

function waitUntilReady() {
  if (socket?.readyState === WebSocket.OPEN && sessionKey) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 15000;
    const timer = setInterval(() => {
      if (socket?.readyState === WebSocket.OPEN && sessionKey) {
        clearInterval(timer);
        resolve();
      } else if (Date.now() >= deadline) {
        clearInterval(timer);
        reject(new Error("RELAY_DISCONNECTED"));
      }
    }, 100);
  });
}

function send(value) {
  if (socket?.readyState !== WebSocket.OPEN) throw new Error("RELAY_DISCONNECTED");
  const data = JSON.stringify(value);
  if (new Blob([data]).size > MAX_FRAME_BYTES) throw new Error("FRAME_TOO_LARGE");
  socket.send(data);
}

function scheduleReconnect() {
  clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(() => connectExisting(), reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, 30000);
}

function rejectPending(reason) {
  for (const waiter of pending.values()) {
    clearTimeout(waiter.timeout);
    waiter.reject(new Error(reason));
  }
  pending.clear();
}

function emitStatus(status) {
  for (const listener of statusListeners) listener(status);
}

function setPairing(next) {
  pairing = next;
  window.dispatchEvent(new CustomEvent("pi:relay-pairing", { detail: next }));
}

function pairingOfferFromLocation() {
  const match = location.pathname.match(/^\/pair\/([A-Za-z0-9_-]{32})$/);
  if (!match) return null;
  const fragment = new URLSearchParams(location.hash.slice(1));
  const ticket = fragment.get("ticket") || "";
  const hostPublicKey = fragment.get("host") || "";
  history.replaceState(null, "", location.pathname);
  if (ticket.length < 32 || hostPublicKey.length < 80) {
    setPairing({ phase: "error", message: "This pairing link is invalid or incomplete." });
    return null;
  }
  return { installationId: match[1], ticket, hostPublicKey };
}

function readMetadata() {
  try {
    const value = JSON.parse(localStorage.getItem(DEVICE_KEY) || "null");
    if (value && typeof value.installationId === "string" && typeof value.deviceId === "string") {
      if (value.protocolVersion === PROTOCOL_VERSION) return value;
      localStorage.removeItem(DEVICE_KEY);
      deleteKeys(value.installationId).catch(() => {});
    }
    return null;
  } catch {
    return null;
  }
}

function writeMetadata(value) {
  try {
    localStorage.setItem(DEVICE_KEY, JSON.stringify(value));
  } catch {
    /* IndexedDB still holds the key; this page works until it closes */
  }
}

function deviceName() {
  const ua = navigator.userAgent || "";
  if (/iPhone/i.test(ua)) return "iPhone";
  if (/iPad/i.test(ua)) return "iPad";
  if (/Android/i.test(ua)) return "Android device";
  return navigator.userAgentData?.platform || navigator.platform || "Web browser";
}

function openDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(DB_STORE);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function saveKeys(id, keys) {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(DB_STORE, "readwrite");
    transaction.objectStore(DB_STORE).put(keys, id);
    transaction.oncomplete = () => { db.close(); resolve(); };
    transaction.onerror = () => { db.close(); reject(transaction.error); };
  });
}

async function loadKeys(id) {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const request = db.transaction(DB_STORE).objectStore(DB_STORE).get(id);
    request.onsuccess = () => { db.close(); resolve(request.result || null); };
    request.onerror = () => { db.close(); reject(request.error); };
  });
}

async function nextCounter(id) {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(DB_STORE, "readwrite");
    const store = transaction.objectStore(DB_STORE);
    const request = store.get(id);
    let counter;
    request.onsuccess = () => {
      const keys = request.result;
      if (!keys?.authPrivate || !keys?.ecdhPrivate) {
        transaction.abort();
        return;
      }
      counter = Number.isSafeInteger(keys.counter) ? keys.counter + 1 : 1;
      if (!Number.isSafeInteger(counter)) {
        transaction.abort();
        return;
      }
      keys.counter = counter;
      store.put(keys, id);
      keyBundle = keys;
    };
    transaction.oncomplete = () => { db.close(); resolve(counter); };
    transaction.onabort = () => { db.close(); reject(new Error("This device needs to be paired again.")); };
    transaction.onerror = () => { db.close(); reject(transaction.error); };
  });
}

async function deleteKeys(id) {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(DB_STORE, "readwrite");
    transaction.objectStore(DB_STORE).delete(id);
    transaction.oncomplete = () => { db.close(); resolve(); };
    transaction.onerror = () => { db.close(); reject(transaction.error); };
  });
}
