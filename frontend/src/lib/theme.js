export const TYPE_COLORS = {
  model: { bg: '#1e3a5f', border: '#3b82f6', text: '#93c5fd' },
  controller: { bg: '#1a3b2a', border: '#22c55e', text: '#86efac' },
  service: { bg: '#3b1f3b', border: '#a855f7', text: '#d8b4fe' },
  job: { bg: '#3b2e1a', border: '#f59e0b', text: '#fcd34d' },
  mailer: { bg: '#3b1a2e', border: '#ec4899', text: '#f9a8d4' },
  concern: { bg: '#1a3b3b', border: '#06b6d4', text: '#67e8f9' },
  component: { bg: '#1a3b3b', border: '#14b8a6', text: '#5eead4' },
  graphql: { bg: '#3b1a3b', border: '#e11d48', text: '#fda4af' },
  serializer: { bg: '#2a3b1a', border: '#84cc16', text: '#bef264' },
  policy: { bg: '#3b2a1a', border: '#f97316', text: '#fdba74' },
  route: { bg: '#2a3b1a', border: '#84cc16', text: '#bef264' },
  middleware: { bg: '#3b2a1a', border: '#f97316', text: '#fdba74' },
  framework: { bg: '#27272a', border: '#71717a', text: '#a1a1aa' },
  flow_step: { bg: '#1e293b', border: '#0ea5e9', text: '#7dd3fc' },
  default: { bg: '#1e293b', border: '#475569', text: '#94a3b8' },
};

export const TYPE_DOT_COLORS = {
  model: '#3b82f6',
  controller: '#22c55e',
  service: '#a855f7',
  job: '#f59e0b',
  mailer: '#ec4899',
  concern: '#06b6d4',
  component: '#14b8a6',
  graphql: '#e11d48',
  serializer: '#84cc16',
  policy: '#f97316',
  route: '#84cc16',
  middleware: '#f97316',
  framework: '#71717a',
  default: '#475569',
};

export const TYPE_DISPLAY_NAMES = {
  model: 'Models',
  controller: 'Controllers',
  service: 'Services',
  job: 'Jobs',
  mailer: 'Mailers',
  concern: 'Concerns',
  component: 'Components',
  graphql: 'GraphQL',
  serializer: 'Serializers',
  policy: 'Policies',
  route: 'Routes',
  middleware: 'Middleware',
  framework: 'Framework',
  flow_step: 'Flow Steps',
};

export function getTypeColor(type) {
  return TYPE_COLORS[type] || TYPE_COLORS.default;
}

export function getTypeDisplayName(type) {
  return TYPE_DISPLAY_NAMES[type] || type.charAt(0).toUpperCase() + type.slice(1) + 's';
}
