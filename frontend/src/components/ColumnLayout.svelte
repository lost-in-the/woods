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
    showMode,
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
        showMode,
      },
    }));
  });

  // Only show edges connected to the center node to avoid inter-neighbor spaghetti.
  const visibleEdges = $derived.by(() => {
    return allEdges
      .filter((e) => visibleNodeIds.has(e.source) && visibleNodeIds.has(e.target))
      .filter((e) => e.source === centerNodeId || e.target === centerNodeId)
      .map((e) => {
        const via = e.data?.via;
        const isAssociation = e.type === 'association';

        // Build style string
        let style = '';
        if (e.data?.isCycle) {
          style = 'stroke: #64748b; stroke-width: 1px; stroke-dasharray: 4 3;';
        } else if (e.data?.through) {
          style = 'stroke: #475569; stroke-width: 1px; opacity: 0.4;';
        } else {
          style = 'stroke: #475569; stroke-width: 1.5px;';
        }

        // Add cardinality markers via CSS
        if (isAssociation && via) {
          if (via === 'has_many') {
            style += ' marker-start: url(#marker-crow-foot); marker-end: url(#marker-bar);';
          } else if (via === 'has_and_belongs_to_many') {
            style += ' marker-start: url(#marker-crow-foot); marker-end: url(#marker-crow-foot);';
          } else {
            // belongs_to, has_one
            style += ' marker-end: url(#marker-bar);';
          }
        }

        const edge = {
          ...e,
          type: isAssociation ? 'smoothstep' : 'default',
          animated: false,
          style,
        };

        // Handle IDs come directly from edge data — no heuristic matching
        if (isAssociation) {
          if (e.data?.sourceHandle) edge.sourceHandle = e.data.sourceHandle;
          if (e.data?.targetHandle) edge.targetHandle = e.data.targetHandle;
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
      <CardinalityMarkers />
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
