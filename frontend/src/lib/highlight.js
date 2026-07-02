/**
 * Source rendering for the detail pane: lightweight Ruby syntax highlighting
 * (no external dependencies — the bundle stays self-contained) composed with
 * <mark> emphasis on whole-word occurrences of connected unit identifiers, so
 * a reader can see where the graph edges actually live in the code.
 *
 * Exact line-span highlighting (from extraction metadata) is a separate,
 * later change; the term marks are a substring approximation.
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

const KEYWORDS = new Set([
  'def', 'end', 'class', 'module', 'if', 'elsif', 'else', 'unless', 'case',
  'when', 'then', 'do', 'while', 'until', 'for', 'in', 'return', 'yield',
  'begin', 'rescue', 'ensure', 'raise', 'self', 'nil', 'true', 'false',
  'and', 'or', 'not', 'super', 'require', 'require_relative', 'include',
  'extend', 'attr_reader', 'attr_writer', 'attr_accessor', 'private',
  'public', 'protected', 'lambda', 'proc', 'new',
]);

// One pass, ordered by precedence: comments and strings first so nothing
// inside them is re-tokenized.
const TOKEN_RE = new RegExp(
  [
    '(#[^\\n]*)', // 1 comment
    '("(?:\\\\.|[^"\\\\])*"|\'(?:\\\\.|[^\'\\\\])*\')', // 2 string
    '(:[A-Za-z_]\\w*[?!]?|\\b[a-z_]\\w*:(?!:))', // 3 symbol / hash key
    '(@@?[A-Za-z_]\\w*|\\$[A-Za-z_]\\w*)', // 4 ivar / gvar
    '(\\b[A-Z]\\w*(?:::[A-Z]\\w*)*\\b)', // 5 constant (possibly namespaced)
    '(\\b\\d[\\d_]*(?:\\.\\d+)?\\b)', // 6 number
    '(\\b[a-z_]\\w*[?!]?)', // 7 bare word (keyword check)
  ].join('|'),
  'g',
);

const GROUP_CLASSES = ['com', 'str', 'sym', 'var', 'const', 'num', null];

/**
 * Build a whole-word matcher for the term list (longest first, so namespaced
 * names win over their prefixes). Boundaries exclude identifier/namespace
 * chars so `Order` doesn't match inside `OrderItem` or `Foo::Order`.
 * @param {Array<string>} terms
 * @returns {?RegExp}
 */
function termMatcher(terms) {
  const unique = [...new Set((terms || []).filter(Boolean))].sort((a, b) => b.length - a.length);
  if (unique.length === 0) return null;
  return new RegExp(`(?<![\\w:])(?:${unique.map(escapeRegExp).join('|')})(?![\\w:])`, 'g');
}

/** Wrap term occurrences in <mark> within already-escaped text. */
function markTerms(escaped, matcher) {
  return matcher ? escaped.replace(matcher, (m) => `<mark>${m}</mark>`) : escaped;
}

/**
 * Return HTML with Ruby syntax highlighting spans and <mark> around
 * whole-word occurrences of any term.
 *
 * @param {string} source
 * @param {Array<string>} terms
 * @returns {string} HTML string
 */
export function highlightSource(source, terms) {
  const matcher = termMatcher(terms);
  const src = String(source ?? '');
  let html = '';
  let last = 0;

  for (const match of src.matchAll(TOKEN_RE)) {
    html += markTerms(escapeHtml(src.slice(last, match.index)), matcher);
    last = match.index + match[0].length;

    const groupIdx = match.slice(1).findIndex((g) => g !== undefined);
    const text = match[0];
    let cls = GROUP_CLASSES[groupIdx];
    if (groupIdx === 6) cls = KEYWORDS.has(text) ? 'kw' : null;

    // Terms are marked inside constants and plain identifiers, not inside
    // strings/comments where a highlight would be noise.
    const inner = cls === 'const' || cls === null
      ? markTerms(escapeHtml(text), matcher)
      : escapeHtml(text);

    html += cls ? `<span class="tok-${cls}">${inner}</span>` : inner;
  }

  html += markTerms(escapeHtml(src.slice(last)), matcher);
  return html;
}
