/**
 * Source-highlighting helpers for the detail pane.
 *
 * Highlighting is a first-cut substring approximation: we mark whole-word
 * occurrences of connected unit identifiers within a unit's source, so a reader
 * can see where the graph edges actually live in the code. Exact line-span
 * highlighting (from extraction metadata) is a separate, later change.
 */

/** Escape HTML special chars so source can be safely injected via {@html}. */
export function escapeHtml(str) {
  return String(str ?? '').replace(
    /[&<>]/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c],
  );
}

/** Escape a string for literal use inside a RegExp. */
function escapeRegExp(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Return HTML-escaped source with <mark> around whole-word occurrences of any
 * term. Terms are matched longest-first so namespaced names win over prefixes,
 * and boundaries exclude identifier/namespace chars so `Order` doesn't match
 * inside `OrderItem` or `Foo::Order`.
 *
 * @param {string} source
 * @param {Array<string>} terms
 * @returns {string} HTML string
 */
export function highlightSource(source, terms) {
  const escaped = escapeHtml(source);
  const unique = [...new Set((terms || []).filter(Boolean))].sort((a, b) => b.length - a.length);
  if (unique.length === 0) return escaped;

  const pattern = unique.map(escapeRegExp).join('|');
  const re = new RegExp(`(?<![\\w:])(?:${pattern})(?![\\w:])`, 'g');
  return escaped.replace(re, (m) => `<mark>${m}</mark>`);
}
