export interface Evidence { field: string; quote: string; page: number; material_id?: string | null }
export interface ExtractedTask {
  course: string; title: string; due_at: string | null; submission: string; requirements: string;
  evidence: Evidence[]; needs_confirmation: string[]; is_update: boolean;
}
export interface Task extends ExtractedTask {
  id: string; version: number; estimated_minutes: number; completed: boolean;
  material_id: string; source_name: string; source_ids: string[]; updated_at: string;
  manual_fields?: string[];
}
export interface Change { field: string; before: string | null; after: string | null }
export interface Candidate {
  id: string; material_id: string; source_name: string; task: ExtractedTask;
  target_id: string | null; expected_version: number | null; requires_target: boolean; changes: Change[];
}
export interface MaterialInput {
  name: string; kind: string; text: string; content_base64: string; mime: string; published_at: string | null;
}
export interface ParseResult { material_id: string; candidates: Candidate[]; elapsed_ms: number; message: string }
export interface ConfirmInput { task: ExtractedTask; estimated_minutes: number; target_id: string | null; expected_version: number | null }
export interface EditInput extends ConfirmInput { completed: boolean }
export interface Interval { start: string; end: string; label: string }
export interface PlanInput { start: string; available: Interval[]; blocked: Interval[] }
export interface Slot { task_id: string; title: string; course: string; start: string; end: string; changed: boolean; reason: string }
export interface Unassigned { task_id: string; title: string; minutes: number; reason: string }
export interface PlanResult { slots: Slot[]; unassigned: Unassigned[]; conflicts: number; input?: PlanInput }
export interface Source { id: string; name: string; kind: string; text: string; pages: string[] }
export interface Health { status: string; model_configured: boolean; timezone: string; version: string }
export interface EvaluationCase {
  id: string; name: string; kind: string; passed: boolean; correct_fields?: number;
  total_fields?: number; missing_tasks?: number; extra_tasks?: number; error?: string;
  differences?: string[]; elapsed_ms?: number;
}
export interface Evaluation {
  status: string; field_accuracy: number | null; passed_cases: number; total_cases: number;
  missing_tasks: number; extra_tasks: number; model_calls_failed: number; elapsed_ms: number;
  note: string; cases: EvaluationCase[];
}
export interface ApiError { detail: string | Object[] }
