// Node type colors: border is the primary accent, bg is a dark tinted version
export const TYPE_COLORS = {
  model:        { bg: '#1e1e3b', border: '#818cf8', text: '#c7d2fe' },
  controller:   { bg: '#1a2e2e', border: '#2dd4bf', text: '#99f6e4' },
  job:          { bg: '#2e2a1a', border: '#fbbf24', text: '#fde68a' },
  service:      { bg: '#1e2433', border: '#64748b', text: '#cbd5e1' },
  poro:         { bg: '#1e2433', border: '#64748b', text: '#cbd5e1' },
  concern:      { bg: '#2a1e3b', border: '#a78bfa', text: '#ddd6fe' },
  mailer:       { bg: '#2e1a2a', border: '#fb7185', text: '#fecdd3' },
  graphql_type: { bg: '#1a2e33', border: '#22d3ee', text: '#a5f3fc' },
  route:        { bg: '#2e2a1a', border: '#fb923c', text: '#fed7aa' },
  migration:    { bg: '#1e2127', border: '#9ca3af', text: '#d1d5db' },
  lib:          { bg: '#1a2e24', border: '#34d399', text: '#a7f3d0' },
  decorator:    { bg: '#2a1e3b', border: '#a78bfa', text: '#ddd6fe' },
  component:    { bg: '#1a2e2e', border: '#2dd4bf', text: '#99f6e4' },
  channel:      { bg: '#1e1e3b', border: '#818cf8', text: '#c7d2fe' },
  serializer:   { bg: '#1a2e24', border: '#34d399', text: '#a7f3d0' },
  policy:       { bg: '#2e2a1a', border: '#fb923c', text: '#fed7aa' },
  middleware:   { bg: '#2e2a1a', border: '#fb923c', text: '#fed7aa' },
  engine:       { bg: '#1e2127', border: '#9ca3af', text: '#d1d5db' },
  framework:    { bg: '#1e2127', border: '#71717a', text: '#a1a1aa' },
  test_mapping: { bg: '#1e2127', border: '#71717a', text: '#a1a1aa' },
  default:      { bg: '#1e293b', border: '#71717a', text: '#94a3b8' },
};

// Dot colors used in sidebar lists (same as border colors)
export const TYPE_DOT_COLORS = Object.fromEntries(
  Object.entries(TYPE_COLORS).map(([k, v]) => [k, v.border])
);

// Human-readable display names
export const TYPE_DISPLAY_NAMES = {
  model: 'Models',
  controller: 'Controllers',
  service: 'Services',
  poro: 'POROs',
  job: 'Jobs',
  mailer: 'Mailers',
  concern: 'Concerns',
  component: 'Components',
  graphql_type: 'GraphQL',
  serializer: 'Serializers',
  policy: 'Policies',
  route: 'Routes',
  middleware: 'Middleware',
  engine: 'Engines',
  decorator: 'Decorators',
  rake_task: 'Rake Tasks',
  state_machine: 'State Machines',
  event: 'Events',
  factory: 'Factories',
  validator: 'Validators',
  channel: 'Channels',
  framework: 'Framework',
  test_mapping: 'Test Mappings',
  migration: 'Migrations',
  lib: 'Libraries',
};

// Functional colors — used across components
export const COLORS = {
  canvasBg: '#0f172a',
  cardBg: '#1e293b',
  centerBorder: '#22c55e',
  centerGlow: 'rgba(34, 197, 94, 0.15)',
  expandedBorder: '#22c55e',
  textPrimary: '#e2e8f0',
  textSecondary: '#94a3b8',
  textMuted: '#64748b',
  edgeDefault: '#475569',
  edgeActive: '#22c55e',
  edgeCycle: '#ef4444',
  expandBtnBorder: '#334155',
  expandBtnText: '#475569',
  expandBtnHoverBorder: '#475569',
  expandBtnHoverText: '#e2e8f0',
  borderSubtle: '#334155',
};

export function getTypeColor(type) {
  return TYPE_COLORS[type] || TYPE_COLORS.default;
}

export function getTypeDisplayName(type) {
  return TYPE_DISPLAY_NAMES[type] || type.charAt(0).toUpperCase() + type.slice(1).replace(/_/g, ' ') + 's';
}
