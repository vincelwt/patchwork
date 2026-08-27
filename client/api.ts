// Every call a client makes to a relay workspace, and nothing platform
// specific: `fetch` is all this needs, so desktop and mobile share it.
// Uploads stay out, because a browser `File` and a phone's file URI are not
// the same thing and each app knows its own.

import type {
  Attachment,
  Automation,
  AutomationDebug,
  AutomationRun,
  Bootstrap,
  Channel,
  Device,
  Health,
  Host,
  Id,
  InboxItem,
  Member,
  Message,
  MessagePage,
  PairingResponse,
  Preview,
  Project,
  Ask,
  Run,
  RunDetail,
  SearchResults,
  Section,
  SystemSkill,
  Task,
  TaskDetail,
  TaskStatus,
  WatchTestResult,
  Workspace,
  WorkspaceSkill,
} from "./types";

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

export class Api {
  constructor(
    public baseUrl: string,
    public token: string,
  ) {}

  protected url(path: string) {
    return `${this.baseUrl.replace(/\/$/, "")}${path}`;
  }

  async request<T>(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<T> {
    const response = await fetch(this.url(path), {
      method,
      headers: {
        Authorization: `Bearer ${this.token}`,
        ...(body === undefined ? {} : { "content-type": "application/json" }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    if (!response.ok) {
      let message = text;
      try {
        message = JSON.parse(text)?.error?.message ?? text;
      } catch {
        // keep the raw body
      }
      throw new ApiError(message, response.status);
    }
    return text ? (JSON.parse(text) as T) : (undefined as T);
  }

  get<T>(path: string) {
    return this.request<T>("GET", path);
  }
  post<T>(path: string, body?: unknown) {
    return this.request<T>("POST", path, body ?? {});
  }
  patch<T>(path: string, body: unknown) {
    return this.request<T>("PATCH", path, body);
  }
  delete<T>(path: string) {
    return this.request<T>("DELETE", path);
  }

  fileUrl(attachment: Attachment) {
    return this.url(attachment.url);
  }

  grantFile(id: Id) {
    return this.post<{ url: string }>(`/api/files/${encodeURIComponent(id)}/grant`);
  }

  grantPreview(id: Id) {
    return this.post<{ url: string }>(`/api/previews/${encodeURIComponent(id)}/grant`);
  }

  bootstrap() {
    return this.get<Bootstrap>("/api/bootstrap");
  }

  /// Live: the relay samples its machine when asked, so this is worth polling.
  health() {
    return this.get<Health>("/api/health");
  }

  createPairing() {
    return this.post<PairingResponse>("/api/pairings");
  }

  devices() {
    return this.get<Device[]>("/api/devices");
  }

  revokeDevice(id: Id) {
    return this.delete(`/api/devices/${encodeURIComponent(id)}`);
  }

  revokeCurrentDevice() {
    return this.delete("/api/devices/current");
  }

  messages(channelId: Id, before?: Id) {
    const query = before ? `?limit=60&before=${before}` : "?limit=60";
    return this.get<MessagePage>(`/api/channels/${channelId}/messages${query}`);
  }

  /// `client_id` is optional and makes a send idempotent: a retry after a
  /// timeout returns the message the first attempt stored instead of a second one.
  send(
    channelId: Id,
    body: Partial<Message> & { attachment_ids?: Id[]; client_id?: Id },
  ) {
    return this.post<Message>(`/api/channels/${channelId}/messages`, body);
  }

  thread(messageId: Id) {
    return this.get<Message[]>(`/api/messages/${messageId}/thread`);
  }

  react(messageId: Id, emoji: string) {
    return this.post<Message>(`/api/messages/${messageId}/reactions`, { emoji });
  }

  createChannel(input: {
    name: string;
    section_name?: string;
    section_id?: Id;
    topic?: string;
  }) {
    return this.post<Channel>("/api/channels", input);
  }

  updateChannel(id: Id, input: Record<string, unknown>) {
    return this.patch<Channel>(`/api/channels/${id}`, input);
  }

  createSection(name: string) {
    return this.post<Section>("/api/sections", { name });
  }

  updateSection(id: Id, name: string) {
    return this.patch<Section>(`/api/sections/${encodeURIComponent(id)}`, { name });
  }

  deleteSection(id: Id) {
    return this.delete(`/api/sections/${encodeURIComponent(id)}`);
  }

  sections() {
    return this.get<Section[]>("/api/sections");
  }

  archiveChannel(id: Id) {
    return this.delete(`/api/channels/${id}`);
  }

  openDm(memberId: Id) {
    return this.post<Channel>("/api/channels/dm", { member_id: memberId });
  }

  tasks() {
    return this.get<Task[]>("/api/tasks");
  }

  task(id: Id) {
    return this.get<TaskDetail>(`/api/tasks/${id}`);
  }

  createTask(input: Record<string, unknown>) {
    return this.post<Task>("/api/tasks", input);
  }

  updateTask(id: Id, input: Record<string, unknown>) {
    return this.patch<Task>(`/api/tasks/${id}`, input);
  }

  /// Only `done` and `canceled` are choices; everything else is derived from
  /// runs and the open ask.
  moveTask(id: Id, status: TaskStatus) {
    return this.updateTask(id, { status });
  }

  deleteTask(id: Id) {
    return this.delete(`/api/tasks/${id}`);
  }

  runTask(id: Id, input?: { agent_id?: Id; prompt?: string }) {
    return this.post<Run>(`/api/tasks/${id}/run`, input ?? {});
  }

  run(id: Id) {
    return this.get<RunDetail>(`/api/runs/${id}`);
  }

  startRun(input: Record<string, unknown>) {
    return this.post<Run>("/api/runs", input);
  }

  cancelRun(id: Id) {
    return this.post(`/api/runs/${id}/cancel`);
  }

  steerRun(
    id: Id,
    input: { prompt: string; mode: "queue" | "interrupt"; attachment_ids: Id[] },
  ) {
    return this.post<{ control_id: Id }>(`/api/runs/${id}/steer`, input);
  }

  ask(id: Id) {
    return this.get<Ask>(`/api/asks/${id}`);
  }

  /// Answering is the only way an ask closes — including an approval, where
  /// the answer is the action label the person clicked.
  answerAsk(id: Id, answer: string[], note = "") {
    return this.post<Ask>(`/api/asks/${id}/answer`, { answer, note });
  }

  inbox(all = false) {
    return this.get<InboxItem[]>(`/api/inbox${all ? "?all=true" : ""}`);
  }

  markRead(id: Id) {
    return this.post(`/api/inbox/${id}/read`);
  }

  markAllRead() {
    return this.post("/api/inbox/read-all");
  }

  members() {
    return this.get<Member[]>("/api/members");
  }

  updateMe(input: { display_name?: string; avatar?: string }) {
    return this.patch<Member>("/api/members/me", input);
  }

  createAgent(input: Record<string, unknown>) {
    return this.post<Member>("/api/agents", input);
  }

  updateAgent(id: Id, input: Record<string, unknown>) {
    return this.patch<Member>(`/api/agents/${id}`, input);
  }

  removeMember(id: Id) {
    return this.delete(`/api/members/${id}`);
  }

  skills() {
    return this.get<WorkspaceSkill[]>("/api/skills");
  }

  createSkill(input: Pick<WorkspaceSkill, "name" | "description" | "instructions">) {
    return this.post<WorkspaceSkill>("/api/skills", input);
  }

  updateSkill(
    id: Id,
    input: Pick<WorkspaceSkill, "name" | "description" | "instructions">,
  ) {
    return this.patch<WorkspaceSkill>(`/api/skills/${id}`, input);
  }

  deleteSkill(id: Id) {
    return this.delete(`/api/skills/${id}`);
  }

  projects() {
    return this.get<Project[]>("/api/projects");
  }

  createProject(input: Record<string, unknown>) {
    return this.post<Project>("/api/projects", input);
  }

  updateProject(id: Id, input: Record<string, unknown>) {
    return this.patch<Project>(`/api/projects/${id}`, input);
  }

  deleteProject(id: Id) {
    return this.delete(`/api/projects/${id}`);
  }

  hosts() {
    return this.get<Host[]>("/api/hosts");
  }

  updateSystemSkill(hostId: Id, path: string, previousContent: string, content: string) {
    return this.patch<SystemSkill>(`/api/hosts/${hostId}/skills`, {
      path,
      previous_content: previousContent,
      content,
    });
  }

  automations() {
    return this.get<Automation[]>("/api/automations");
  }

  createAutomation(input: Record<string, unknown>) {
    return this.post<Automation>("/api/automations", input);
  }

  updateAutomation(id: Id, input: Record<string, unknown>) {
    return this.patch<Automation>(`/api/automations/${id}`, input);
  }

  deleteAutomation(id: Id) {
    return this.delete(`/api/automations/${id}`);
  }

  runAutomation(id: Id) {
    return this.post<AutomationRun>(`/api/automations/${id}/run`);
  }

  testAutomation(id: Id) {
    return this.post<WatchTestResult>(`/api/automations/${id}/test`);
  }

  automationDebug(id: Id) {
    return this.get<AutomationDebug>(`/api/automations/${id}/debug`);
  }

  previews() {
    return this.get<Preview[]>("/api/previews");
  }

  startPreview(input: Record<string, unknown>) {
    return this.post<Preview>("/api/previews", input);
  }

  stopPreview(id: Id) {
    return this.post(`/api/previews/${id}/stop`);
  }

  search(query: string) {
    return this.get<SearchResults>(`/api/search?q=${encodeURIComponent(query)}`);
  }

  updateWorkspace(input: {
    name?: string;
    icon?: string;
    icon_file_id?: Id;
    task_prefix?: string;
    autonomy?: string;
  }) {
    return this.patch<Workspace>("/api/workspace", input);
  }

  invites() {
    return this.get<{ code: string; used_at?: number; email?: string }[]>(
      "/api/invites",
    );
  }

  createInvite(input: { email?: string; is_admin: boolean }) {
    return this.post<{ code: string }>("/api/invites", input);
  }
}
