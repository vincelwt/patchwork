import { useCallback, useState } from "react";
import { Linking, Pressable, StyleSheet, Text, View } from "react-native";
import { Image } from "expo-image";
import * as ImagePicker from "expo-image-picker";

import type { Attachment, Id } from "@client/types";
import { bytes } from "@/lib/format";
import { usePairedSession } from "@/lib/session";
import { useTheme } from "@/lib/theme";

const MAX_IMAGE_BYTES = 20 * 1024 * 1024;

export interface PendingImage {
  attachment: Attachment;
  localUri: string;
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
  form.append(
    "file",
    {
      uri: asset.uri,
      name,
      type: asset.mimeType || "image/jpeg",
    } as unknown as Blob,
  );
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
    setUploading(true);
    try {
      for (const asset of result.assets) {
        const attachment = await uploadImage(session.baseUrl, session.token, asset, taskId);
        setPending((current) => [...current, { attachment, localUri: asset.uri }]);
      }
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setUploading(false);
    }
  }, [session, taskId]);

  return {
    pending,
    uploading,
    error,
    pick,
    remove: (id: Id) => setPending((current) => current.filter((item) => item.attachment.id !== id)),
    clear: () => setPending([]),
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
      {images.map(({ attachment, localUri }) => (
        <View key={attachment.id} style={[styles.thumbWrap, { borderColor: theme.line }]}>
          <Image source={localUri} style={styles.thumb} contentFit="cover" />
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={`Remove ${attachment.file_name}`}
            onPress={() => onRemove(attachment.id)}
            style={[styles.remove, { backgroundColor: theme.danger }]}
          >
            <Text style={{ color: "white", fontWeight: "700" }}>×</Text>
          </Pressable>
        </View>
      ))}
    </View>
  );
}

export function AttachmentView({ attachment }: { attachment: Attachment }) {
  const { session } = usePairedSession();
  const theme = useTheme();
  if (!session) return null;
  const url = `${session.baseUrl.replace(/\/$/, "")}${attachment.url}`;
  if (attachment.mime.startsWith("image/")) {
    return (
      <Image
        source={{ uri: url, headers: { Authorization: `Bearer ${session.token}` } }}
        style={[styles.image, { backgroundColor: theme.surface }]}
        contentFit="cover"
        transition={120}
        cachePolicy="none"
        accessibilityLabel={attachment.file_name}
      />
    );
  }
  const open = async () => {
    const response = await fetch(
      `${session.baseUrl.replace(/\/$/, "")}/api/files/${attachment.id}/grant`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${session.token}` },
      },
    );
    if (response.ok) await Linking.openURL((await response.json()).url);
  };
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`Open ${attachment.file_name}`}
      onPress={() => void open()}
      style={[styles.file, { backgroundColor: theme.surface, borderColor: theme.line }]}
    >
      <Text numberOfLines={1} style={[styles.fileName, { color: theme.text }]}>{attachment.file_name}</Text>
      <Text style={{ color: theme.muted }}>
        {attachment.mime.startsWith("video/") ? "Video · " : ""}{bytes(attachment.size)}
      </Text>
    </Pressable>
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
