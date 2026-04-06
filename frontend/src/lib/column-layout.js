/**
 * Compute Svelte Flow node positions for the bidirectional column layout.
 * Columns are spaced horizontally, nodes stacked vertically within each column.
 */

const COLUMN_WIDTH = 280;
const COLUMN_GAP = 100;
const NODE_GAP = 16;
const BASE_NODE_HEIGHT = 44;
const COLUMN_ROW_HEIGHT = 20;
const HEADER_HEIGHT = 32;

/**
 * Estimate the pixel height of a node.
 * Center nodes show full column detail; neighbors show compact.
 * @param {Object} node - Svelte Flow node
 * @param {boolean} isCenter - Whether this is the center node
 * @returns {number}
 */
function estimateNodeHeight(node, isCenter) {
  const cols = node.data?.columns?.length || 0;
  if (isCenter && cols > 0) return BASE_NODE_HEIGHT + cols * COLUMN_ROW_HEIGHT;
  if (cols > 0) return BASE_NODE_HEIGHT + 20; // compact summary row
  if (node.data?.attributes?.length) return BASE_NODE_HEIGHT + 24;
  return BASE_NODE_HEIGHT;
}

/**
 * Position nodes in a bidirectional column layout.
 *
 * @param {Array} nodes - Svelte Flow node objects to position
 * @param {Map<string, number>} columnMap - nodeId => column index (0 = center, negative = left, positive = right)
 * @param {string} centerNodeId - The center node
 * @returns {Array} Positioned nodes with updated position.x, position.y, sourcePosition, targetPosition
 */
export function layoutColumns(nodes, columnMap, centerNodeId) {
  // Group nodes by column
  const columns = new Map();
  for (const node of nodes) {
    const col = columnMap.get(node.id) ?? 0;
    if (!columns.has(col)) columns.set(col, []);
    columns.get(col).push(node);
  }

  // Sort column indices
  const sortedCols = [...columns.keys()].sort((a, b) => a - b);
  const minCol = sortedCols[0] || 0;

  // Position each column
  const positioned = [];
  for (const colIndex of sortedCols) {
    const colNodes = columns.get(colIndex);
    const xOffset = (colIndex - minCol) * (COLUMN_WIDTH + COLUMN_GAP);

    let yOffset = HEADER_HEIGHT; // leave room for column header

    for (const node of colNodes) {
      const height = estimateNodeHeight(node, node.id === centerNodeId);
      positioned.push({
        ...node,
        position: { x: xOffset, y: yOffset },
        sourcePosition: 'right',
        targetPosition: 'left',
        style: node.id === centerNodeId
          ? `border-color: #22c55e; box-shadow: 0 0 20px rgba(34, 197, 94, 0.15);`
          : undefined,
      });
      yOffset += height + NODE_GAP;
    }
  }

  return positioned;
}

/**
 * Get the column boundaries for rendering column headers and expand buttons.
 * @param {Map<string, number>} columnMap
 * @returns {Array<{colIndex: number, x: number, width: number}>}
 */
export function getColumnBounds(columnMap) {
  const colIndices = new Set(columnMap.values());
  const sorted = [...colIndices].sort((a, b) => a - b);
  const minCol = sorted[0] || 0;

  return sorted.map((colIndex) => ({
    colIndex,
    x: (colIndex - minCol) * (COLUMN_WIDTH + COLUMN_GAP),
    width: COLUMN_WIDTH,
  }));
}
