const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function base64URL(bytes) {
  let binary = "";
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  for (let offset = 0; offset < view.length; offset += 0x8000) {
    binary += String.fromCharCode(...view.subarray(offset, offset + 0x8000));
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64URL(value) {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (value.length % 4)) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function challengeText(installationId, deviceId, nonce) {
  return `pi-remote-v1:${installationId}:${deviceId}:${nonce}`;
}

export function pairingTranscript(installationId, deviceId, name, ecdhPublicKey, authPublicKey) {
  return ["pi-remote-pair-v1", installationId, deviceId, name, ecdhPublicKey, authPublicKey.x, authPublicKey.y].join("\0");
}

export async function pairingCredentials(ticket, installationId, deviceId, name, ecdhPublicKey, authPublicKey) {
  const ticketBytes = fromBase64URL(ticket);
  const hmacKey = await crypto.subtle.importKey("raw", ticketBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const proofBytes = new Uint8Array(await crypto.subtle.sign(
    "HMAC",
    hmacKey,
    encoder.encode(pairingTranscript(installationId, deviceId, name, ecdhPublicKey, authPublicKey))
  ));
  const ticketHash = base64URL(await crypto.subtle.digest("SHA-256", encoder.encode(ticket)));
  const value = ((proofBytes[0] * 0x1000000) + (proofBytes[1] << 16) + (proofBytes[2] << 8) + proofBytes[3]) % 1000000;
  return { ticketHash, proof: base64URL(proofBytes), verificationCode: String(value).padStart(6, "0") };
}

export async function deriveSessionKey(privateKey, hostPublicKey, installationId, deviceId) {
  const publicKey = await crypto.subtle.importKey(
    "raw",
    fromBase64URL(hostPublicKey),
    { name: "ECDH", namedCurve: "P-256" },
    false,
    []
  );
  const secret = await crypto.subtle.deriveBits({ name: "ECDH", public: publicKey }, privateKey, 256);
  const material = await crypto.subtle.importKey("raw", secret, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: encoder.encode(installationId),
      info: encoder.encode(`pi-remote-v1:${deviceId}`)
    },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"]
  );
}

export async function encryptJSON(value, key, direction) {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = encoder.encode(JSON.stringify(value));
  const data = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce, additionalData: encoder.encode(`pi-remote-v1:${direction}`) },
    key,
    plaintext
  );
  return { nonce: base64URL(nonce), data: base64URL(data) };
}

export async function decryptJSON(payload, key, direction) {
  const plaintext = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: fromBase64URL(payload.nonce),
      additionalData: encoder.encode(`pi-remote-v1:${direction}`)
    },
    key,
    fromBase64URL(payload.data)
  );
  return JSON.parse(decoder.decode(plaintext));
}

export const utf8 = (value) => encoder.encode(value);
