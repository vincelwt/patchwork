// The shared client plus calls that only a browser can make.

import { Api as SharedApi, ApiError } from "@client/api";
import type { Attachment, Id } from "@client/types";

export { ApiError };

export class Api extends SharedApi {
  async file(path: string) {
    const response = await fetch(this.url(path), {
      headers: { Authorization: `Bearer ${this.token}` },
    });
    if (!response.ok) {
      throw new ApiError("Could not open that file", response.status);
    }
    return response.blob();
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

  async upload(file: File, taskId?: Id) {
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
