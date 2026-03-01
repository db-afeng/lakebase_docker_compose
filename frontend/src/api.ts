import type { Task, DbInfo, HealthStatus } from "./types";

const API = "/api";

export async function fetchTasks(): Promise<{
  tasks: Task[];
  source: string;
}> {
  const res = await fetch(`${API}/tasks`);
  if (!res.ok) throw new Error("Failed to fetch tasks");
  return res.json();
}

export async function searchTasks(
  q: string
): Promise<{ tasks: Task[]; source: string }> {
  const res = await fetch(`${API}/tasks/search?q=${encodeURIComponent(q)}`);
  if (!res.ok) throw new Error("Search failed");
  return res.json();
}

export async function createTask(data: {
  title: string;
  description: string;
}): Promise<Task> {
  const res = await fetch(`${API}/tasks`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(data),
  });
  if (!res.ok) {
    const err = await res.json();
    throw new Error(err.error || "Failed to create task");
  }
  return res.json();
}

export async function updateTask(
  id: string,
  data: Partial<Pick<Task, "title" | "description" | "status">>
): Promise<Task> {
  const res = await fetch(`${API}/tasks/${id}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(data),
  });
  if (!res.ok) throw new Error("Failed to update task");
  return res.json();
}

export async function toggleTask(id: string): Promise<Task> {
  const res = await fetch(`${API}/tasks/${id}/toggle`, { method: "PATCH" });
  if (!res.ok) throw new Error("Failed to toggle task");
  return res.json();
}

export async function deleteTask(id: string): Promise<void> {
  const res = await fetch(`${API}/tasks/${id}`, { method: "DELETE" });
  if (!res.ok) throw new Error("Failed to delete task");
}

export async function fetchHealth(): Promise<HealthStatus> {
  const res = await fetch(`${API}/health`);
  if (!res.ok) throw new Error("Failed to fetch health");
  return res.json();
}

export async function fetchDbInfo(): Promise<DbInfo> {
  const res = await fetch(`${API}/info`);
  if (!res.ok) throw new Error("Failed to fetch db info");
  return res.json();
}
