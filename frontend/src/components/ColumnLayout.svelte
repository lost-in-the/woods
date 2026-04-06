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
  import { layoutColumns } from '../lib/column-layout.js';
  import { assignColumns } from '../lib/graph-state.js';

  let {
    allNodes,
    allEdges,
    visibleNodeIds,
    centerNodeId,
    expandedBranches,
    loading,
    focusNodeId,
    onNodeSelect,
    onCanvasClick,
  } = $props();

  const nodeTypes = { model: ModelNode, compact: CompactNode };

  // Filter to visible nodes and edges
  const visibleNodes = $derived.by(() => {
    return allNodes.filter((n) => visibleNodeIds.has(n.id)).map((n) => ({
      ...n,
      type: n.data?.unitType === 'model' ? 'model' : 'compact',
      data: {
        ...n.data,
        isCenter: n.id === centerNodeId,
      },
    }));
  });

  // Only show edges connected to the center node to avoid inter-neighbor spaghetti.
  // Route through FK/PK column handles on center for Liam ERD-style connections.
  const visibleEdges = $derived.by(() => {
    const centerNode = allNodes.find((n) => n.id === centerNodeId);
    const centerColumns = centerNode?.data?.columns || [];

    return allEdges
      .filter((e) => visibleNodeIds.has(e.source) && visibleNodeIds.has(e.target))
      .filter((e) => e.source === centerNodeId || e.target === centerNodeId)
      .map((e) => {
        const edge = {
          ...e,
          style: e.data?.isCycle
            ? 'stroke: #64748b; stroke-width: 1px; stroke-dasharray: 4 3;'
            : 'stroke: #475569; stroke-width: 1.5px',
          animated: false,
        };

        if (e.source === centerNodeId) {
          // Center depends on target → route through FK column on center's left side
          const fkCol = findFkColumn(centerColumns, e.target);
          if (fkCol) edge.sourceHandle = `col-left-${fkCol.name}`;
        } else {
          // Source depends on center → route to center's PK column on right side
          const pkCol = centerColumns.find((c) => c.primary);
          if (pkCol) edge.targetHandle = `col-right-${pkCol.name}`;
        }

        return edge;
      });
  });

  // Compute column assignments and layout
  const columnMap = $derived(
    assignColumns(centerNodeId, visibleNodeIds, allEdges, expandedBranches)
  );

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

  /**
   * Find the FK column on the center node that matches a target model name.
   * e.g., target "Country" → column "country_id", target "PlanPrice" → "plan_price_id"
   */
  function findFkColumn(columns, targetId) {
    const snake = targetId
      .replace(/::/g, '/')
      .replace(/([a-z\d])([A-Z])/g, '$1_$2')
      .toLowerCase()
      .replace(/\//g, '_');
    const fkName = snake + '_id';
    return columns.find((c) => c.name === fkName);
  }

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
    <SvelteFlow
      bind:nodes={layoutedNodes}
      bind:edges={layoutedEdges}
      {nodeTypes}
      onnodeclick={handleNodeClick}
      onpaneclick={handlePaneClick}
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
