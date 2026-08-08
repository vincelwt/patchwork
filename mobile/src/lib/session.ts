// What this phone is allowed to reach, and nothing else.
//
// A phone is paired from Desktop and receives its own device token. Whatever
// that pairing flow looks like, it ends here: `savePairedSession` is the only
// writer of credentials in the app, and the token lives in the keychain, never
// in a link, a preference file, or a text field.

import { useCallback, useEffect, useState } from "react";
import * as SecureStore from "expo-secure-store";
import { Api } from "@client/api";

const KEY = "patchwork.session";

export interface PairedSession {
  /// One workspace's own base, `{relay}/w/{workspace_id}`.
  baseUrl: string;
  /// The member token Desktop issued for this device.
  token: string;
}

/// The single door into a signed-in app. A pairing flow calls this once it has
/// proof from Desktop; there is deliberately no other way in.
export async function savePairedSession(session: PairedSession): Promise<void> {
  await SecureStore.setItemAsync(KEY, JSON.stringify(session), {
    // Readable only on this device, only while it is unlocked, and never
    // carried to a new phone by a backup.
    keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
  });
}

export async function loadPairedSession(): Promise<PairedSession | null> {
  const raw = await SecureStore.getItemAsync(KEY);
  if (!raw) return null;
  try {
    const saved = JSON.parse(raw) as Partial<PairedSession>;
    if (!saved.baseUrl || !saved.token) return null;
    return { baseUrl: saved.baseUrl, token: saved.token };
  } catch {
    // Unreadable is the same as not paired: pair again rather than guess.
    return null;
  }
}

export async function clearPairedSession(): Promise<void> {
  await SecureStore.deleteItemAsync(KEY);
}

export function apiFor(session: PairedSession): Api {
  return new Api(session.baseUrl, session.token);
}

/// `undefined` while the keychain is still being read. The difference between
/// "not paired" and "not known yet" is the difference between showing the
/// sign-in screen and flashing it at someone who is signed in.
export function usePairedSession() {
  const [session, setSession] = useState<PairedSession | null | undefined>(
    undefined,
  );

  useEffect(() => {
    let current = true;
    loadPairedSession()
      .catch(() => null)
      .then((loaded) => {
        if (current) setSession(loaded);
      });
    return () => {
      current = false;
    };
  }, []);

  const signOut = useCallback(async () => {
    await clearPairedSession();
    setSession(null);
  }, []);

  return { session, signOut };
}
