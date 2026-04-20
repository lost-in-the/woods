<script>
  let { node, onClose } = $props();

  const d = $derived(node?.data || {});

  const rows = $derived.by(() => {
    const r = [
      ['Type', d.unitType || node?.type || '-'],
      ['File', d.filePath || '-'],
      ['Namespace', d.namespace || '-'],
      ['PageRank', d.pagerank ? d.pagerank.toFixed(6) : '-'],
    ];
    if (d.isHub) r.push(['Role', 'Hub']);
    if (d.isBridge) r.push(['Role', 'Bridge']);
    if (d.isOrphan) r.push(['Role', 'Orphan']);
    if (d.dependencyCount != null) r.push(['Dependencies', d.dependencyCount]);
    if (d.dependentCount != null) r.push(['Dependents', d.dependentCount]);
    if (d.operations) r.push(['Operations', d.operationCount || d.operations.length]);
    if (d.stepType) r.push(['Step Type', d.stepType]);
    return r;
  });

  const columns = $derived(d.columns || []);

  function columnIcon(col) {
    if (col.primary) return '\u{1F511}';
    if (col.foreign) return '\u{1F517}';
    if (!col.nullable) return '\u25C6';
    return '\u25C7';
  }
</script>

{#if node}
  <div class="detail-panel open">
    <button class="close-btn" aria-label="Close detail panel" onclick={onClose}>&times;</button>
    <h3>{node.id}</h3>
    {#each rows as [label, value]}
      <div class="detail-row">
        <span class="detail-label">{label}</span>
        <span class="detail-value">{value}</span>
      </div>
    {/each}

    {#if columns.length > 0}
      <div class="detail-section">
        <div class="detail-section-title">Columns</div>
        {#each columns as col}
          <div class="detail-column-row">
            <span class="detail-column-icon">{columnIcon(col)}</span>
            <span class="detail-column-name">{col.name}</span>
            <span class="detail-column-type">{col.type || ''}</span>
          </div>
        {/each}
      </div>
    {/if}
  </div>
{/if}
