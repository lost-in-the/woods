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
  const showMode = $derived(data?.showMode || 'all_fields');

  const COLLAPSE_THRESHOLD = 20;
  const VISIBLE_WHEN_COLLAPSED = 8;

  let expanded = $state(false);

  const visibleColumns = $derived.by(() => {
    if (showMode === 'table_name') return [];
    if (showMode === 'key_only') return columns.filter((c) => c.primary || c.foreign);
    // all_fields mode — use collapse logic
    if (columns.length <= COLLAPSE_THRESHOLD || expanded) return columns;

    // Show first N + all PK/FK columns
    const first = columns.slice(0, VISIBLE_WHEN_COLLAPSED);
    const keyColumns = columns.slice(VISIBLE_WHEN_COLLAPSED).filter(
      (c) => c.primary || c.foreign
    );
    const seen = new Set(first.map((c) => c.name));
    const extra = keyColumns.filter((c) => !seen.has(c.name));
    return [...first, ...extra];
  });

  const hiddenCount = $derived(
    columns.length <= COLLAPSE_THRESHOLD || expanded
      ? 0
      : columns.length - visibleColumns.length
  );

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

  // Liam-style handle: small circle visible on FK/PK columns, invisible on others
  function handleStyle(side, col) {
    const isKey = col.primary || col.foreign;
    const base = side === 'left'
      ? 'left: -5px;'
      : 'right: -5px;';
    if (isKey) {
      return `${base} width: 8px; height: 8px; background: #1e293b; border: 1.5px solid #64748b; border-radius: 50%;`;
    }
    return `${base} width: 6px; height: 6px; background: transparent; border: none; opacity: 0;`;
  }
</script>

<div
  class="model-node {highlightClass}"
  style="background:{colors.bg}; border-color:{borderColor}; color:{colors.text};"
>
  <!-- Card-level handles — invisible, used only for non-column edges -->
  <Handle
    type="target"
    position={targetPosition || Position.Left}
    class="card-handle"
  />

  <div class="node-header" style={isCenter ? `background: ${COLORS.centerGlow};` : ''}>
    <span class="type-dot" style="background:{colors.border};"></span>
    <span class="node-name">{truncated}</span>
    {#if connectionCount > 50}
      <span class="badge connectivity" title="{connectionCount} total connections">{connectionCount}</span>
    {/if}
  </div>

  {#each visibleColumns as col}
    <div class="column-row">
      <Handle
        type="target"
        position={Position.Left}
        id={`${data.label}-${col.name}`}
        style={handleStyle('left', col)}
      />
      <span class="col-icon">{columnIcon(col)}</span>
      <span class="col-name">{col.name}</span>
      <span class="col-type">{col.type || ''}</span>
      <Handle
        type="source"
        position={Position.Right}
        id={`${data.label}-${col.name}`}
        style={handleStyle('right', col)}
      />
    </div>
  {/each}
  {#if hiddenCount > 0}
    <button class="expand-columns-row" onclick={() => expanded = true}>
      + {hiddenCount} more
    </button>
  {/if}

  <Handle
    type="source"
    position={sourcePosition || Position.Right}
    class="card-handle"
  />
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

  .expand-columns-row {
    display: block;
    width: 100%;
    padding: 3px 10px;
    font-size: 9px;
    color: #64748b;
    background: transparent;
    border: none;
    border-top: 1px solid #334155;
    cursor: pointer;
    text-align: left;
  }

  .expand-columns-row:hover {
    color: #94a3b8;
    background: rgba(51, 65, 85, 0.3);
  }

  .node-dimmed {
    opacity: 0.3;
  }

  /* Hide card-level handles — only column handles should be visible */
  :global(.card-handle) {
    width: 1px !important;
    height: 1px !important;
    background: transparent !important;
    border: none !important;
    opacity: 0 !important;
    min-width: 0 !important;
    min-height: 0 !important;
  }
</style>
