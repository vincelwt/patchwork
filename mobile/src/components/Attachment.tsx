import { useCallback, useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { Image } from "expo-image";
import * as ImagePicker from "expo-image-picker";

import { evidenceKind } from "@client/evidence";
import type { Attachment, Id } from "@client/types";
import { bytes } from "@/lib/format";
import { usePairedSession } from "@/lib/session";
import { useTheme } from "@/lib/theme";
import { EvidenceView, opensExternally, useGrantedOpen } from "./Evidence";
import { ErrorNotice, Sheet } from "./ui";

const MAX_IMAGE_BYTES = 20 * 1024 * 1024;

export interface PendingImage {
  id: Id;
  attachment?: Attachment;
  localUri: string;
  fileName: string;
}

async function uploadImage(
  baseUrl: string,
  token: string,
  asset: ImagePicker.ImagePickerAsset,
  taskId?: Id,
): Promise<Attachment> {
  if (asset.fileSize && asset.fileSize > MAX_IMAGE_BYTES) {
    throw new Error("That image is larger than 20 MB.");
  }
  const name = asset.fileName || `image-${Date.now()}.${asset.mimeType?.split("/")[1] || "jpg"}`;
  if ((asset.fileSize ?? 0) > 8 * 1024 * 1024) {
    const blob = await (await fetch(asset.uri)).blob();
    const created = await fetch(`${baseUrl.replace(/\/$/, "")}/api/uploads`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        file_name: name,
        mime: asset.mimeType || "image/jpeg",
        size: blob.size,
        task_id: taskId,
      }),
    });
    if (!created.ok) throw new Error((await created.text()) || "Could not start upload.");
    const upload = (await created.json()) as { id: Id; chunk_size: number };
    for (let offset = 0; offset < blob.size; offset += upload.chunk_size) {
      const response = await fetch(
        `${baseUrl.replace(/\/$/, "")}/api/uploads/${upload.id}?offset=${offset}`,
        {
          method: "PUT",
          headers: { Authorization: `Bearer ${token}` },
          body: blob.slice(offset, offset + upload.chunk_size),
        },
      );
      if (!response.ok) throw new Error((await response.text()) || "Could not upload image.");
    }
    const completed = await fetch(
      `${baseUrl.replace(/\/$/, "")}/api/uploads/${upload.id}/complete`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` },
      },
    );
    if (!completed.ok) throw new Error((await completed.text()) || "Could not finish upload.");
    return (await completed.json()) as Attachment;
  }

  const form = new FormData();
  if (taskId) form.append("task_id", taskId);
  // Expo's standards-based fetch cannot serialize React Native's `{ uri }`
  // FormData extension. A real Blob works in both the native and Expo fetches.
  form.append("file", await (await fetch(asset.uri)).blob(), name);
  const response = await fetch(`${baseUrl.replace(/\/$/, "")}/api/files`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: form,
  });
  if (!response.ok) throw new Error((await response.text()) || "Could not upload that image.");
  return (await response.json()) as Attachment;
}

export function useImageAttachments(taskId?: Id) {
  const { session } = usePairedSession();
  const [pending, setPending] = useState<PendingImage[]>([]);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState("");

  const pick = useCallback(async () => {
    if (!session) return;
    setError("");
    const permission = await ImagePicker.requestMediaLibraryPermissionsAsync();
    if (!permission.granted) {
      setError("Allow photo access to attach an image.");
      return;
    }
    const result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ["images"],
      allowsMultipleSelection: true,
      quality: 0.9,
      selectionLimit: 8,
    });
    if (result.canceled) return;
    const selected = result.assets.map((asset, index) => ({
      id: `${Date.now()}-${index}`,
      asset,
      localUri: asset.uri,
      fileName: asset.fileName || "Image",
    }));
    // Show the local image immediately. Uploading is transport state, not a
    // reason to hide what the person just attached.
    setPending((current) => [
      ...current,
      ...selected.map(({ id, localUri, fileName }) => ({ id, localUri, fileName })),
    ]);
    setUploading(true);
    try {
      for (const item of selected) {
        try {
          const attachment = await uploadImage(session.baseUrl, session.token, item.asset, taskId);
          setPending((current) => current.map((pending) =>
            pending.id === item.id ? { ...pending, attachment } : pending,
          ));
        } catch (caught) {
          setError(caught instanceof Error ? caught.message : String(caught));
        }
      }
    } finally {
      setUploading(false);
    }
  }, [session, taskId]);

  return {
    pending,
    uploading,
    error,
    ready: pending.every((item) => !!item.attachment),
    attachmentIds: pending.flatMap((item) => item.attachment ? [item.attachment.id] : []),
    pick,
    remove: (id: Id) => {
      setPending((current) => current.filter((item) => item.id !== id));
      setError("");
    },
    clear: () => {
      setPending([]);
      setError("");
    },
  };
}

export function PendingImages({
  images,
  onRemove,
}: {
  images: PendingImage[];
  onRemove: (id: Id) => void;
}) {
  const theme = useTheme();
  if (!images.length) return null;
  return (
    <View style={styles.pending}>
      {images.map(({ id, localUri, fileName }) => (
        <View key={id} style={[styles.thumbWrap, { borderColor: theme.line }]}>
          <Image source={localUri} style={styles.thumb} contentFit="cover" />
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={`Remove ${fileName}`}
            onPress={() => onRemove(id)}
            style={[styles.remove, { backgroundColor: theme.danger }]}
          >
            <Text style={{ color: "white", fontWeight: "700" }}>×</Text>
          </Pressable>
        </View>
      ))}
    </View>
  );
}

/// In the transcript: a screenshot to look at, or a line to press. What can be
/// read on the phone opens over the app; a video, a page or a download goes to
/// whatever the phone uses for it.
export function AttachmentView({ attachment }: { attachment: Attachment }) {
  const { session } = usePairedSession();
  const theme = useTheme();
  const { open, busy, error } = useGrantedOpen();
  const [viewing, setViewing] = useState(false);
  const kind = evidenceKind(attachment.mime, attachment.file_name);
  const press = () =>
    opensExternally(kind) ? void open((api) => api.grantFile(attachment.id)) : setViewing(true);
  const label = attachment.caption || attachment.file_name;
  if (!session) return null;

  return (
    <>
      {kind === "image" ? (
        <Pressable accessibilityRole="button" accessibilityLabel={`Open ${label}`} onPress={press}>
          <Image
            source={{
              uri: `${session.baseUrl.replace(/\/$/, "")}${attachment.url}`,
              headers: { Authorization: `Bearer ${session.token}` },
            }}
            style={[styles.image, { backgroundColor: theme.surface }]}
            contentFit="cover"
            transition={120}
            cachePolicy="none"
            accessibilityLabel={label}
          />
        </Pressable>
      ) : (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={`Open ${label}`}
          accessibilityState={{ busy }}
          onPress={press}
          style={[styles.file, { backgroundColor: theme.surface, borderColor: theme.line }]}
        >
          <Text numberOfLines={1} style={[styles.fileName, { color: theme.text }]}>{label}</Text>
          <Text style={{ color: theme.muted }}>
            {kind === "video" ? "Video · " : ""}{bytes(attachment.size)}{busy ? " · opening…" : ""}
          </Text>
        </Pressable>
      )}
      <ErrorNotice message={error} />
      <Sheet visible={viewing} title={label} onClose={() => setViewing(false)}>
        {viewing ? <EvidenceView attachment={attachment} /> : null}
      </Sheet>
    </>
  );
}

const styles = StyleSheet.create({
  pending: { flexDirection: "row", flexWrap: "wrap", gap: 8, paddingVertical: 6 },
  thumbWrap: { width: 70, height: 70, borderRadius: 10, borderWidth: StyleSheet.hairlineWidth },
  thumb: { width: "100%", height: "100%", borderRadius: 10 },
  remove: { position: "absolute", right: -6, top: -6, width: 24, height: 24, borderRadius: 12, alignItems: "center", justifyContent: "center" },
  image: { width: "100%", maxWidth: 460, aspectRatio: 4 / 3, borderRadius: 12, marginTop: 8 },
  file: { marginTop: 8, minHeight: 48, borderRadius: 10, borderWidth: StyleSheet.hairlineWidth, padding: 10, justifyContent: "center" },
  fileName: { fontWeight: "600", marginBottom: 2 },
});
