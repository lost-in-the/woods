import dagre from '@dagrejs/dagre';

const NODE_WIDTH = 172;
const BASE_HEIGHT = 44;
const COLUMN_ROW_HEIGHT = 20;
const ATTRIBUTE_ROW_HEIGHT = 24;

function getNodeHeight(node) {
  if (node.data?.columns?.length) {
    return BASE_HEIGHT + node.data.columns.length * COLUMN_ROW_HEIGHT;
  }
  if (node.data?.attributes?.length) {
    return BASE_HEIGHT + ATTRIBUTE_ROW_HEIGHT;
  }
  return BASE_HEIGHT;
}

export function getLayoutedElements(nodes, edges, direction = 'TB') {
  const g = new dagre.graphlib.Graph().setDefaultEdgeLabel(() => ({}));
  g.setGraph({ rankdir: direction, nodesep: 60, ranksep: 120 });

  nodes.forEach((node) => {
    const height = getNodeHeight(node);
    g.setNode(node.id, { width: NODE_WIDTH, height });
  });

  edges.forEach((edge) => {
    g.setEdge(edge.source, edge.target);
  });

  dagre.layout(g);

  const isHorizontal = direction === 'LR';

  const layoutedNodes = nodes.map((node) => {
    const pos = g.node(node.id);
    const height = getNodeHeight(node);
    return {
      ...node,
      targetPosition: isHorizontal ? 'left' : 'top',
      sourcePosition: isHorizontal ? 'right' : 'bottom',
      position: {
        x: pos.x - NODE_WIDTH / 2,
        y: pos.y - height / 2,
      },
    };
  });

  return { nodes: layoutedNodes, edges };
}
