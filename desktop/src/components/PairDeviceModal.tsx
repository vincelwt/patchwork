import { useEffect, useState } from "react";
import { toDataURL } from "qrcode";

import type { Device, PairingResponse } from "@client/types";
import { relative } from "../lib/format";
import { useApi } from "../lib/store";
import { Modal } from "./common";

export function PairDeviceModal({ onClose }: { onClose: () => void }) {
  const api = useApi();
  const [pairing, setPairing] = useState<PairingResponse>();
  const [qr, setQr] = useState("");
  const [devices, setDevices] = useState<Device[]>([]);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState("");

  const refreshDevices = () => api.devices().then(setDevices).catch(() => setDevices([]));
  const create = async () => {
    setError("");
    try {
      const next = await api.createPairing();
      const link = `patchwork://pair?base=${encodeURIComponent(next.workspace_url)}&secret=${encodeURIComponent(next.secret)}`;
      setPairing(next);
      setQr(await toDataURL(link, { width: 264, margin: 1, errorCorrectionLevel: "M" }));
      setCopied(false);
    } catch (caught) {
      setError(String((caught as Error).message ?? caught));
    }
  };

  useEffect(() => {
    void refreshDevices();
    void create();
  }, []);

  const link = pairing
    ? `patchwork://pair?base=${encodeURIComponent(pairing.workspace_url)}&secret=${encodeURIComponent(pairing.secret)}`
    : "";

  return (
    <Modal
      title="Pair phone or tablet"
      subtitle="The code expires after five minutes and gives the new device its own revocable key."
      onClose={onClose}
      wide
      actions={
        <>
          <button className="button quiet" onClick={() => void create()}>
            New code
          </button>
          <button className="button primary" onClick={onClose}>
            Done
          </button>
        </>
      }
    >
      <div style={{ display: "grid", gridTemplateColumns: "232px minmax(0, 1fr)", gap: 20, alignItems: "start" }}>
        <div style={{ textAlign: "center" }}>
          {qr ? (
            <img
              src={qr}
              width={232}
              height={232}
              alt="Pairing QR code"
              style={{ borderRadius: 12, background: "white", padding: 6 }}
            />
          ) : (
            <div className="notice">Creating a code…</div>
          )}
          {pairing && <div className="form-help">Scan before this code expires</div>}
          {link && (
            <button
              className="button quiet"
              style={{ marginTop: 8 }}
              onClick={() => {
                void navigator.clipboard.writeText(link);
                setCopied(true);
              }}
            >
              {copied ? "Pairing link copied" : "Copy pairing link"}
            </button>
          )}
        </div>
        <div style={{ minWidth: 0 }}>
          <div className="section-head">
            <span className="section-title">Your devices</span>
          </div>
          {devices.map((device) => (
            <div className="row" key={device.id}>
              <span className="grow">
                <span className="name">{device.label || "Unnamed device"}</span>
                <span className="sub">
                  Added {relative(device.created_at)}
                  {device.last_used ? ` · used ${relative(device.last_used)}` : ""}
                </span>
              </span>
              {device.current ? (
                <span className="chip positive">this device</span>
              ) : (
                <button
                  className="button quiet danger"
                  onClick={async () => {
                    await api.revokeDevice(device.id);
                    await refreshDevices();
                  }}
                >
                  Revoke
                </button>
              )}
            </div>
          ))}
          <div className="notice" style={{ marginTop: 12 }}>
            Patchwork Relay gives this workspace a secure HTTPS connection automatically. No network setup is needed on either device.
          </div>
        </div>
      </div>
      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}
