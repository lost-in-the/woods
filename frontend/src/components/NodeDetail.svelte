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
    if (d.operations) r.push(['Operations', d.operationCount || d.operations.length]);
    if (d.stepType) r.push(['Step Type', d.stepType]);
    return r;
  });
</script>

{#if node}
  <div class="sidebar open">
    <button class="close-btn" onclick={onClose}>&times;</button>
    <h3>{node.id}</h3>
    {#each rows as [label, value]}
      <div class="detail-row">
        <span class="detail-label">{label}</span>
        <span class="detail-value">{value}</span>
      </div>
    {/each}
  </div>
{/if}
