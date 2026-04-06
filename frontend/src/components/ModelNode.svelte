<script>
  import { Handle, Position } from '@xyflow/svelte';
  import { getTypeColor, COLORS } from '../lib/theme.js';

  let { data, sourcePosition, targetPosition } = $props();

  const colors = $derived(getTypeColor(data?.unitType));
  const label = $derived(data?.label || '');
  const truncated = $derived(
    label.length > 28 ? label.slice(0, 26) + '...' : label
  );
  const columns = $derived(data?.columns || []);
  const isCenter = $derived(data?.isCenter || false);

  const highlightClass = $derived.by(() => {
    if (isCenter) return 'node-center';
    if (data?.isActive === undefined) return '';
    if (data?.isActive) return 'node-active';
    if (data?.isHighlighted) return 'node-highlighted';
    return 'node-dimmed';
  });

  const borderColor = $derived(
    isCenter ? COLORS.centerBorder : colors.border
  );

  const connectionCount = $derived(
    (data?.dependencyCount || 0) + (data?.dependentCount || 0)
  );

  function columnIcon(col) {
    if (col.primary) return '\u{1F511}';
    if (col.foreign) return '\u{1F517}';
    if (!col.nullable) return '\u25C6';
    return '\u25C7';
  }
</script>

<div
  class="model-node {highlightClass}"
  style="background:{colors.bg}; border-color:{borderColor}; color:{colors.text};"
>
  <!-- Card-level handles for non-column edges -->
  <Handle type="target" position={targetPosition || Position.Left} />

  <div class="node-header" style={isCenter ? `background: ${COLORS.centerGlow};` : ''}>
    <span class="type-dot" style="background:{colors.border};"></span>
    <span class="node-name">{truncated}</span>
    {#if connectionCount > 50}
      <span class="badge connectivity" title="{connectionCount} total connections">{connectionCount}</span>
    {/if}
  </div>

  {#if isCenter}
    {#each columns as col, i}
      <div class="column-row">
        <Handle
          type="target"
          position={Position.Left}
          id={`col-left-${col.name}`}
          style="top: auto; left: -4px; width: 8px; height: 8px; background: {col.foreign ? COLORS.edgeActive : 'transparent'}; border: none;"
        />
        <span class="col-icon">{columnIcon(col)}</span>
        <span class="col-name">{col.name}</span>
        <span class="col-type">{col.type || ''}</span>
        <Handle
          type="source"
          position={Position.Right}
          id={`col-right-${col.name}`}
          style="top: auto; right: -4px; width: 8px; height: 8px; background: {col.primary ? COLORS.edgeActive : 'transparent'}; border: none;"
        />
      </div>
    {/each}
  {:else if columns.length > 0}
    <div class="compact-summary">
      {columns.length} columns
    </div>
  {/if}

  <Handle type="source" position={sourcePosition || Position.Right} />
</div>

<style>
  .model-node {
    border: 2px solid;
    border-radius: 8px;
    min-width: 160px;
    max-width: 240px;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    position: relative;
    transition: opacity 0.15s, box-shadow 0.15s;
  }

  .node-center {
    box-shadow: 0 0 20px rgba(34, 197, 94, 0.15);
  }

  .node-header {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    border-radius: 6px 6px 0 0;
  }

  .type-dot {
    width: 8px;
    height: 8px;
    border-radius: 2px;
    flex-shrink: 0;
  }

  .node-name {
    font-size: 11px;
    font-weight: 600;
    line-height: 1.3;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
  }

  .badge {
    font-size: 8px;
    font-weight: 600;
    padding: 1px 4px;
    border-radius: 3px;
    flex-shrink: 0;
  }

  .badge.connectivity {
    background: #334155;
    color: #94a3b8;
  }

  .column-row {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 2px 10px;
    font-size: 10px;
    border-top: 1px solid #334155;
    position: relative;
  }

  .col-icon {
    width: 14px;
    text-align: center;
    flex-shrink: 0;
    font-size: 10px;
  }

  .col-name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .col-type {
    opacity: 0.6;
    flex-shrink: 0;
    font-size: 9px;
  }

  .compact-summary {
    padding: 3px 10px;
    font-size: 9px;
    color: #64748b;
    border-top: 1px solid #334155;
  }

  .node-dimmed {
    opacity: 0.3;
  }
</style>
