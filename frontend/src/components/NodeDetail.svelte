<script>
  import { fetchUnitSource } from '../lib/api.js';
  import { highlightSource } from '../lib/highlight.js';

  let { node, onClose, highlights = [] } = $props();

  const d = $derived(node?.data || {});

  let sourceData = $state(null);
  let sourceLoading = $state(false);
  let sourceError = $state(false);
  let showSource = $state(false);

  // Fetch source lazily whenever the selected node changes; cancel stale loads.
  $effect(() => {
    const id = node?.id;
    sourceData = null;
    sourceError = false;
    if (!id) return;

    let cancelled = false;
    sourceLoading = true;
    fetchUnitSource(id)
      .then((data) => { if (!cancelled) sourceData = data; })
      .catch(() => { if (!cancelled) sourceError = true; })
      .finally(() => { if (!cancelled) sourceLoading = false; });

    return () => { cancelled = true; };
  });

  // Links are built server-side (SourceLinks) so container→local path mapping
  // and repo pinning live in one tested place.
  const editorUrl = $derived(sourceData?.editorUrl || null);
  const highlightedHtml = $derived(
    sourceData?.sourceCode ? highlightSource(sourceData.sourceCode, highlights) : '',
  );

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
  <div class="detail-panel open" class:source-open={showSource && sourceData?.sourceCode}>
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

    <div class="detail-section">
      <div class="detail-section-title source-header">
        <span>Source</span>
        <div class="source-links">
          {#if editorUrl}
            <a class="source-link" href={editorUrl} title="Open in editor">editor</a>
          {/if}
          {#if sourceData?.blobUrl}
            <a class="source-link" href={sourceData.blobUrl} target="_blank" rel="noopener" title="View on GitHub">GitHub</a>
          {/if}
          <button
            class="source-toggle"
            onclick={() => (showSource = !showSource)}
            disabled={!sourceData?.sourceCode}
          >{showSource ? 'Hide' : 'Show'}</button>
        </div>
      </div>

      {#if sourceLoading}
        <div class="source-status">Loading…</div>
      {:else if sourceError}
        <div class="source-status">Source unavailable</div>
      {:else if showSource && sourceData?.sourceCode}
        {#if sourceData.live === false}
          <div class="source-status">Extraction snapshot — file not readable here</div>
        {/if}
        <pre class="source-code"><code>{@html highlightedHtml}</code></pre>
      {/if}
    </div>
  </div>
{/if}
