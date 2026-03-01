import { useCallback, useEffect, useRef, useState } from "react";
import type { Task, DbInfo, HealthStatus } from "./types";
import * as api from "./api";
import "./App.css";

type Filter = "all" | "pending" | "completed";

function StatusBar({
  health,
  dbInfo,
  dataSource,
}: {
  health: HealthStatus | null;
  dbInfo: DbInfo | null;
  dataSource: string;
}) {
  const dot = (ok: boolean | null) =>
    ok === null ? "dot gray" : ok ? "dot green" : "dot red";

  return (
    <div className="status-bar">
      <div className="status-item">
        <span className={dot(health?.postgres ?? null)} />
        PostgreSQL
      </div>
      <div className="status-item">
        <span className={dot(health?.redis ?? null)} />
        Redis
      </div>
      {dbInfo && (
        <div className="status-item db-source">
          {dbInfo.db_source} &middot; {dbInfo.db_host}
        </div>
      )}
      <div className="status-item source-badge">
        Source: <strong>{dataSource}</strong>
      </div>
    </div>
  );
}

function TaskForm({ onSubmit }: { onSubmit: (title: string, desc: string) => void }) {
  const [title, setTitle] = useState("");
  const [desc, setDesc] = useState("");

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!title.trim()) return;
    onSubmit(title.trim(), desc.trim());
    setTitle("");
    setDesc("");
  };

  return (
    <form className="task-form" onSubmit={handleSubmit}>
      <input
        className="task-input"
        placeholder="What needs to be done?"
        value={title}
        onChange={(e) => setTitle(e.target.value)}
        autoFocus
      />
      <input
        className="task-input desc-input"
        placeholder="Description (optional)"
        value={desc}
        onChange={(e) => setDesc(e.target.value)}
      />
      <button type="submit" className="btn btn-primary" disabled={!title.trim()}>
        Add
      </button>
    </form>
  );
}

function TaskRow({
  task,
  onToggle,
  onDelete,
  onUpdate,
}: {
  task: Task;
  onToggle: (id: string) => void;
  onDelete: (id: string) => void;
  onUpdate: (id: string, data: { title: string; description: string }) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [editTitle, setEditTitle] = useState(task.title);
  const [editDesc, setEditDesc] = useState(task.description);
  const done = task.status === "completed";

  const save = () => {
    if (!editTitle.trim()) return;
    onUpdate(task.id, { title: editTitle.trim(), description: editDesc.trim() });
    setEditing(false);
  };

  const cancel = () => {
    setEditTitle(task.title);
    setEditDesc(task.description);
    setEditing(false);
  };

  if (editing) {
    return (
      <li className="task-item editing">
        <div className="edit-fields">
          <input
            className="task-input"
            value={editTitle}
            onChange={(e) => setEditTitle(e.target.value)}
            autoFocus
            onKeyDown={(e) => e.key === "Enter" && save()}
          />
          <input
            className="task-input desc-input"
            value={editDesc}
            onChange={(e) => setEditDesc(e.target.value)}
            placeholder="Description"
            onKeyDown={(e) => e.key === "Enter" && save()}
          />
          <div className="edit-actions">
            <button className="btn btn-primary btn-sm" onClick={save}>
              Save
            </button>
            <button className="btn btn-ghost btn-sm" onClick={cancel}>
              Cancel
            </button>
          </div>
        </div>
      </li>
    );
  }

  return (
    <li className={`task-item ${done ? "done" : ""}`}>
      <button
        className={`checkbox ${done ? "checked" : ""}`}
        onClick={() => onToggle(task.id)}
        aria-label={done ? "Mark pending" : "Mark complete"}
      >
        {done && (
          <svg viewBox="0 0 14 14" fill="none">
            <path
              d="M11.5 3.5L5.5 10L2.5 7"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        )}
      </button>
      <div className="task-content" onDoubleClick={() => setEditing(true)}>
        <span className="task-title">{task.title}</span>
        {task.description && (
          <span className="task-desc">{task.description}</span>
        )}
      </div>
      <div className="task-actions">
        <button className="btn btn-ghost btn-sm" onClick={() => setEditing(true)}>
          Edit
        </button>
        <button className="btn btn-danger btn-sm" onClick={() => onDelete(task.id)}>
          Delete
        </button>
      </div>
    </li>
  );
}

export default function App() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [health, setHealth] = useState<HealthStatus | null>(null);
  const [dbInfo, setDbInfo] = useState<DbInfo | null>(null);
  const [dataSource, setDataSource] = useState("postgres");
  const [filter, setFilter] = useState<Filter>("all");
  const [searchQuery, setSearchQuery] = useState("");
  const [error, setError] = useState("");
  const debounceRef = useRef<ReturnType<typeof setTimeout>>();

  const loadTasks = useCallback(async () => {
    try {
      const data = await api.fetchTasks();
      setTasks(data.tasks);
      setDataSource(data.source);
      setError("");
    } catch {
      setError("Failed to load tasks. Is the backend running?");
    }
  }, []);

  useEffect(() => {
    loadTasks();
    api.fetchHealth().then(setHealth).catch(() => {});
    api.fetchDbInfo().then(setDbInfo).catch(() => {});
  }, [loadTasks]);

  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);

    if (!searchQuery.trim()) {
      loadTasks();
      return;
    }

    debounceRef.current = setTimeout(async () => {
      try {
        const data = await api.searchTasks(searchQuery);
        setTasks(data.tasks);
        setDataSource(data.source);
        setError("");
      } catch {
        setError("Search failed");
      }
    }, 300);

    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, [searchQuery, loadTasks]);

  const handleCreate = async (title: string, description: string) => {
    try {
      await api.createTask({ title, description });
      setSearchQuery("");
      await loadTasks();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Create failed");
    }
  };

  const handleToggle = async (id: string) => {
    try {
      const updated = await api.toggleTask(id);
      setTasks((prev) => prev.map((t) => (t.id === id ? updated : t)));
    } catch {
      setError("Toggle failed");
    }
  };

  const handleUpdate = async (
    id: string,
    data: { title: string; description: string }
  ) => {
    try {
      const updated = await api.updateTask(id, data);
      setTasks((prev) => prev.map((t) => (t.id === id ? updated : t)));
    } catch {
      setError("Update failed");
    }
  };

  const handleDelete = async (id: string) => {
    try {
      await api.deleteTask(id);
      setTasks((prev) => prev.filter((t) => t.id !== id));
    } catch {
      setError("Delete failed");
    }
  };

  const filtered = tasks.filter((t) => {
    if (filter === "pending") return t.status === "pending";
    if (filter === "completed") return t.status === "completed";
    return true;
  });

  const pendingCount = tasks.filter((t) => t.status === "pending").length;

  return (
    <div className="app">
      <header>
        <h1>To-Do List</h1>
        <p className="subtitle">Lakebase Branching Demo</p>
      </header>

      <StatusBar health={health} dbInfo={dbInfo} dataSource={dataSource} />

      {error && <div className="error-banner">{error}</div>}

      <div className="search-bar">
        <svg className="search-icon" viewBox="0 0 20 20" fill="currentColor">
          <path
            fillRule="evenodd"
            d="M8 4a4 4 0 100 8 4 4 0 000-8zM2 8a6 6 0 1110.89 3.476l4.817 4.817a1 1 0 01-1.414 1.414l-4.816-4.816A6 6 0 012 8z"
            clipRule="evenodd"
          />
        </svg>
        <input
          type="text"
          placeholder="Search tasks (powered by Redis)..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
        />
        {searchQuery && (
          <button
            className="search-clear"
            onClick={() => setSearchQuery("")}
            aria-label="Clear search"
          >
            &times;
          </button>
        )}
      </div>

      <TaskForm onSubmit={handleCreate} />

      <section className="task-section">
        <div className="task-header">
          <span className="task-count">
            {pendingCount} task{pendingCount !== 1 ? "s" : ""} remaining
          </span>
          <div className="filter-tabs">
            {(["all", "pending", "completed"] as Filter[]).map((f) => (
              <button
                key={f}
                className={`filter-btn ${filter === f ? "active" : ""}`}
                onClick={() => setFilter(f)}
              >
                {f.charAt(0).toUpperCase() + f.slice(1)}
              </button>
            ))}
          </div>
        </div>

        {filtered.length === 0 ? (
          <p className="empty">
            {searchQuery
              ? "No matching tasks found."
              : filter !== "all"
                ? `No ${filter} tasks.`
                : "No tasks yet. Add one above."}
          </p>
        ) : (
          <ul className="task-list">
            {filtered.map((t) => (
              <TaskRow
                key={t.id}
                task={t}
                onToggle={handleToggle}
                onDelete={handleDelete}
                onUpdate={handleUpdate}
              />
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
