// The shared client plus calls that only a browser can make.

import { Api as SharedApi, ApiError } from "@client/api";
import type { Attachment, Id, Task } from "@client/types";

export { ApiError };

export class Api extends SharedApi {
  constructor(
    baseUrl: string,
    token: string,
    private readonly onTaskCreated?: (task: Task) => void,
  ) {
    super(baseUrl, token);
  }

  override async createTask(input: Record<string, unknown>) {
    const task = await super.createTask(input);
    // The POST response is already authoritative. Publish it immediately
    // instead of making the creating window wait for its own realtime echo;
    // that echo remains useful to every other connected client and is an
    // idempotent upsert here when it arrives.
    this.onTaskCreated?.(task);
    return task;
  }

  async file(path: string) {
    const chunks: Blob[] = [];
    const chunkSize = 8 * 1024 * 1024;
    let offset = 0;
    let total = Infinity;
    let type = "application/octet-stream";

    while (offset < total) {
      const response = await fetch(this.url(path), {
        headers: {
          Authorization: `Bearer ${this.token}`,
          Range: `bytes=${offset}-${offset + chunkSize - 1}`,
        },
      });
      const contentRange = response.headers.get("content-range") ?? "";
      if (response.status === 416 && contentRange === "bytes */0") return new Blob([]);
      if (!response.ok) throw new ApiError("Could not open that file", response.status);
      if (response.status === 200) return response.blob();

      const range = /bytes (\d+)-(\d+)\/(\d+)/.exec(contentRange);
      if (!range) throw new ApiError("The relay returned an invalid file range", response.status);
      chunks.push(await response.blob());
      offset = Number(range[2]) + 1;
      total = Number(range[3]);
      type = response.headers.get("content-type") || type;
    }
    return new Blob(chunks, { type });
  }

  async openFile(path: string) {
    const url = URL.createObjectURL(await this.file(path));
    const link = document.createElement("a");
    link.href = url;
    link.target = "_blank";
    link.rel = "noreferrer noopener";
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
  }

  async downloadFile(path: string, name: string) {
    const url = URL.createObjectURL(await this.file(path));
    const link = document.createElement("a");
    link.href = url;
    link.download = name;
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
  }

  async upload(file: File, taskId?: Id) {
    if (file.size > 8 * 1024 * 1024) {
      const upload = await this.post<{ id: Id; chunk_size: number }>("/api/uploads", {
        file_name: file.name,
        mime: file.type,
        size: file.size,
        task_id: taskId,
      });
      for (let offset = 0; offset < file.size; offset += upload.chunk_size) {
        const response = await fetch(
          this.url(`/api/uploads/${upload.id}?offset=${offset}`),
          {
            method: "PUT",
            headers: { Authorization: `Bearer ${this.token}` },
            body: file.slice(offset, offset + upload.chunk_size),
          },
        );
        if (!response.ok) throw new ApiError(await response.text(), response.status);
      }
      return this.post<Attachment>(`/api/uploads/${upload.id}/complete`);
    }

    const form = new FormData();
    if (taskId) form.append("task_id", taskId);
    form.append("file", file);
    const response = await fetch(this.url("/api/files"), {
      method: "POST",
      headers: { Authorization: `Bearer ${this.token}` },
      body: form,
    });
    if (!response.ok) {
      throw new ApiError(await response.text(), response.status);
    }
    return (await response.json()) as Attachment;
  }
}
