import { useEffect, useState } from "react";
import { useApi } from "./store";

/// Browser-safe URL for a workspace file. The relay requires authentication,
/// so images are fetched first rather than putting a bearer token in the URL.
export function useFileUrl(path: string) {
  const api = useApi();
  const [url, setUrl] = useState("");

  useEffect(() => {
    if (!path) {
      setUrl("");
      return;
    }
    let current = "";
    let cancelled = false;
    void api
      .file(path)
      .then((blob) => {
        if (cancelled) return;
        current = URL.createObjectURL(blob);
        setUrl(current);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
      if (current) URL.revokeObjectURL(current);
    };
  }, [api, path]);

  return url;
}

export function useGrantedFileUrl(id?: string) {
  const api = useApi();
  const [url, setUrl] = useState("");

  useEffect(() => {
    setUrl("");
    if (!id) return;
    let cancelled = false;
    void api
      .grantFile(id)
      .then((granted) => {
        if (!cancelled) setUrl(granted.url);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [api, id]);

  return url;
}

export function usePreviewUrl(id?: string, live = false) {
  const api = useApi();
  const [url, setUrl] = useState("");

  useEffect(() => {
    setUrl("");
    if (!id || !live) return;
    let cancelled = false;
    void api
      .grantPreview(id)
      .then((granted) => {
        if (!cancelled) setUrl(granted.url);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [api, id, live]);

  return url;
}
