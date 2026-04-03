export const TYPE_COLORS = {
  model: { bg: '#1e3a5f', border: '#3b82f6', text: '#93c5fd' },
  controller: { bg: '#3b1f3b', border: '#a855f7', text: '#d8b4fe' },
  service: { bg: '#1a3b2a', border: '#22c55e', text: '#86efac' },
  job: { bg: '#3b2e1a', border: '#f59e0b', text: '#fcd34d' },
  mailer: { bg: '#3b1a2e', border: '#ec4899', text: '#f9a8d4' },
  concern: { bg: '#2a2a3b', border: '#6366f1', text: '#a5b4fc' },
  component: { bg: '#1a3b3b', border: '#14b8a6', text: '#5eead4' },
  graphql: { bg: '#3b1a3b', border: '#e11d48', text: '#fda4af' },
  serializer: { bg: '#2a3b1a', border: '#84cc16', text: '#bef264' },
  policy: { bg: '#3b2a1a', border: '#f97316', text: '#fdba74' },
  route: { bg: '#1a2a3b', border: '#0ea5e9', text: '#7dd3fc' },
  middleware: { bg: '#27272a', border: '#71717a', text: '#a1a1aa' },
  framework: { bg: '#27272a', border: '#71717a', text: '#a1a1aa' },
  flow_step: { bg: '#1e293b', border: '#0ea5e9', text: '#7dd3fc' },
  default: { bg: '#1e293b', border: '#475569', text: '#94a3b8' },
};

export function getTypeColor(type) {
  return TYPE_COLORS[type] || TYPE_COLORS.default;
}
