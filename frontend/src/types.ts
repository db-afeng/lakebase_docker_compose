export interface Task {
  id: string;
  title: string;
  description: string;
  status: "pending" | "completed";
  created_at: string;
  updated_at: string;
}

export interface DbInfo {
  db_source: string;
  db_host: string;
  db_name: string;
}

export interface HealthStatus {
  postgres: boolean;
  redis: boolean;
}
