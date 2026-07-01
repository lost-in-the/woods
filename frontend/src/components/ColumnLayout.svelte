<script>
  import {
    SvelteFlow,
    Controls,
    MiniMap,
    Background,
  } from '@xyflow/svelte';
  import ModelNode from './ModelNode.svelte';
  import CompactNode from './CompactNode.svelte';
  import FocusNode from './FocusNode.svelte';
  import CardinalityMarkers from './CardinalityMarkers.svelte';
  import EdgeLegend from './EdgeLegend.svelte';
  import { layoutColumns } from '../lib/column-layout.js';
  import { assignColumns } from '../lib/graph-state.js';
  import { viaColor } from '../lib/edge-style.js';

  let {
    allNodes,
    allEdges,
    visibleNodeIds,
    centerNodeId,
    expandedBranches,
    loading,
    focusNodeId,
    showMode,
    queriedIds = new Set(),
    onNodeSelect,
    onCanvasClick,
  } = $props();

  const nodeTypes = { model: ModelNode, compact: CompactNode };

  // Filter to visible nodes and edges
  const visibleNodes = $derived.by(() => {
    // In query mode (queriedIds non-empty), dim nodes that were only pulled in
    // as neighbors so the queried set stands out.
    const scoping = queriedIds.size > 0;
    return allNodes.filter((n) => visibleNodeIds.has(n.id)).map((n) => ({
      ...n,
      type: n.data?.unitType === 'model' ? 'model' : 'compact',
      data: {
        ...n.data,
        isCenter: n.id === centerNodeId,
        dimmed: scoping && !queriedIds.has(n.id),
        showMode,
      },
    }));
  });

  // Compute column assignments — needed before edge rendering for direction fix.
  const columnMap = $derived(
    assignColumns(centerNodeId, visibleNodeIds, allEdges, expandedBranches)
  );

  // Only show edges connected to the center node to avoid inter-neighbor spaghetti.
  // For visual correctness, edges must flow left-to-right (source on left, target on
  // right). SvelteFlow routes source→RIGHT handle and target→LEFT handle by default.
  // When the backend edge direction puts the source to the RIGHT of the target (e.g.,
  // Order→Account where Order is in the right column), we swap source/target and their
  // handles/markers so the edge exits the inner side of each node toward center.
  const visibleEdges = $derived.by(() => {
    return allEdges
      .filter((e) => visibleNodeIds.has(e.source) && visibleNodeIds.has(e.target))
      .filter((e) => e.source === centerNodeId || e.target === centerNodeId)
      .map((e) => {
        const via = e.data?.via;
        const isAssociation = e.type === 'association';

        // Check if we need to swap direction for visual left-to-right flow.
        // columnMap: negative columns = left, 0 = center, positive = right.
        const srcCol = columnMap.get(e.source) ?? 0;
        const tgtCol = columnMap.get(e.target) ?? 0;
        const needsSwap = srcCol > tgtCol;

        // Resolve source/target after potential swap
        const source = needsSwap ? e.target : e.source;
        const target = needsSwap ? e.source : e.target;

        // Edge style: color by relationship (:via) so associations, renders,
        // navigation, and plain references read differently. Width/dash encode
        // through-associations (dimmed) and cycles (dashed).
        const color = viaColor(via);
        let style = '';
        if (isAssociation && e.data?.through) {
          style = `stroke: ${color}; stroke-width: 1px; opacity: 0.4;`;
        } else if (e.data?.isCycle) {
          style = `stroke: ${color}; stroke-width: 1px; stroke-dasharray: 4 3;`;
        } else {
          style = `stroke: ${color}; stroke-width: 1.5px;`;
        }

        // Cardinality markers — assigned by via type, then swapped if edge was flipped.
        // marker-start appears at the source (left) end, marker-end at the target (right).
        let markerStart;
        let markerEnd;
        if (isAssociation && via) {
          if (via === 'has_many') {
            markerStart = 'url(#marker-crow-foot)';
            markerEnd = 'url(#marker-bar)';
          } else if (via === 'has_and_belongs_to_many') {
            markerStart = 'url(#marker-crow-foot)';
            markerEnd = 'url(#marker-crow-foot)';
          } else {
            // belongs_to, has_one: bar on target (PK) end only
            markerEnd = 'url(#marker-bar)';
          }

          // Swap markers when edge direction was flipped
          if (needsSwap) {
            [markerStart, markerEnd] = [markerEnd, markerStart];
          }
        }

        // Handle routing for association edges
        let sourceHandle;
        let targetHandle;
        if (isAssociation) {
          sourceHandle = needsSwap ? e.data?.targetHandle : e.data?.sourceHandle;
          targetHandle = needsSwap ? e.data?.sourceHandle : e.data?.targetHandle;
        }

        const edge = {
          ...e,
          source,
          target,
          type: 'smoothstep',
          animated: false,
          style,
        };

        if (markerStart) edge.markerStart = markerStart;
        if (markerEnd) edge.markerEnd = markerEnd;
        if (sourceHandle) edge.sourceHandle = sourceHandle;
        if (targetHandle) edge.targetHandle = targetHandle;

        return edge;
      });
  });

  let layoutedNodes = $state.raw([]);
  let layoutedEdges = $state.raw([]);

  $effect(() => {
    if (visibleNodes.length === 0) {
      layoutedNodes = [];
      layoutedEdges = [];
      return;
    }
    layoutedNodes = layoutColumns(visibleNodes, columnMap, centerNodeId);
    layoutedEdges = visibleEdges;
  });

  function handleNodeClick({ node }) {
    onNodeSelect?.(node);
  }

  function handlePaneClick() {
    onCanvasClick?.();
  }
</script>

<div class="flow-container">
  {#if loading}
    <div class="loading-overlay">Loading graph...</div>
  {:else if allNodes.length === 0}
    <div class="loading-overlay">
      No extraction data available. Run <code>rake woods:extract</code> first.
    </div>
  {:else}
    <CardinalityMarkers />
    <SvelteFlow
      bind:nodes={layoutedNodes}
      bind:edges={layoutedEdges}
      {nodeTypes}
      onnodeclick={handleNodeClick}
      onpaneclick={handlePaneClick}
      nodesConnectable={false}
      edgesUpdatable={false}
      nodesDraggable={true}
      fitView
      fitViewOptions={{ padding: 0.12, maxZoom: 0.85 }}
      minZoom={0.1}
      maxZoom={2}
    >
      <Controls />
      <MiniMap />
      <Background />
      <FocusNode nodeId={focusNodeId} />
    </SvelteFlow>
    <EdgeLegend edges={layoutedEdges} />
  {/if}
</div>

<style>
  .flow-container {
    flex: 1;
    position: relative;
  }

  .loading-overlay {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100%;
    color: #64748b;
    font-size: 14px;
  }

  .loading-overlay code {
    background: #1e293b;
    padding: 2px 6px;
    border-radius: 4px;
    font-size: 13px;
  }
</style>
