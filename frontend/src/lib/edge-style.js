/**
 * Maps a dependency edge's `via` relationship to a visual category and color,
 * so users can tell associations from navigation, renders, and plain code
 * references at a glance. The graph data already carries `data.via`.
 */

export const VIA_CATEGORIES = [
  {
    key: 'association',
    label: 'Association',
    color: '#60a5fa',
    vias: ['belongs_to', 'has_many', 'has_one', 'has_and_belongs_to_many'],
  },
  { key: 'render', label: 'Render', color: '#a78bfa', vias: ['render'] },
  {
    key: 'navigation',
    label: 'Navigation',
    color: '#34d399',
    vias: ['link_to', 'redirect_to', 'form_action'],
  },
  { key: 'reference', label: 'Reference', color: '#64748b', vias: ['code_reference'] },
];

const DEFAULT_CATEGORY = VIA_CATEGORIES.find((c) => c.key === 'reference');

const BY_VIA = new Map();
for (const category of VIA_CATEGORIES) {
  for (const via of category.vias) BY_VIA.set(via, category);
}

/**
 * Category for a via label (unknown/empty vias fall back to "reference").
 * @param {?string} via
 * @returns {{key: string, label: string, color: string}}
 */
export function viaCategory(via) {
  return BY_VIA.get(via) || DEFAULT_CATEGORY;
}

/**
 * Stroke color for a via label.
 * @param {?string} via
 * @returns {string}
 */
export function viaColor(via) {
  return viaCategory(via).color;
}

/**
 * The distinct categories present in a set of edges, in canonical order —
 * for rendering a legend of only what's on screen.
 * @param {Array<{data?: {via?: string}}>} edges
 * @returns {Array<{key: string, label: string, color: string}>}
 */
export function categoriesInEdges(edges) {
  const present = new Set((edges || []).map((e) => viaCategory(e.data?.via).key));
  return VIA_CATEGORIES.filter((c) => present.has(c.key));
}
