/* Woods Explorer application. Self-contained: no external dependencies.
   Reads the embedded woods-explorer/1 payload and renders four views
   (Overview, Graph, ERD, Table) plus a detail panel, search, and a path
   finder. All data-driven text is inserted via textContent — never HTML. */
(function () {
  'use strict';

  /* ================= data ================= */

  var DATA;
  try {
    DATA = JSON.parse(document.getElementById('woods-data').textContent);
  } catch (e) {
    document.body.textContent = 'Woods Explorer: embedded data is corrupt (' + e.message + ')';
    return;
  }
  var NODES = DATA.nodes || [];
  var EDGES = DATA.edges || [];
  var ANALYSIS = DATA.analysis || {};
  var GROUPS = DATA.groups || [];
  var N = NODES.length;

  /* Validated categorical palettes — one set per theme (docs/EXPLORER.md).
     Family order matches DATA.groups slot order; changing the order breaks
     the palette's CVD-separation contract. 'other' wears the muted ink. */
  var PALETTES = {
    light: {
      data: '#2a78d6', http: '#1baf7a', view: '#eda100', domain: '#008300',
      async: '#4a3aa7', policy: '#e34948', test: '#e87ba4', support: '#eb6834',
      other: '#898781'
    },
    dark: {
      data: '#4b90ea', http: '#1baf7a', view: '#c98500', domain: '#008300',
      async: '#6f61d6', policy: '#e66767', test: '#dd6493', support: '#d95926',
      other: '#898781'
    }
  };

  /* ================= tiny DOM helper ================= */

  function h(tag, attrs) {
    var el = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        var v = attrs[k];
        if (v === null || v === undefined || v === false) return;
        if (k === 'class') el.className = v;
        else if (k === 'text') el.textContent = v;
        else if (k.indexOf('on') === 0 && typeof v === 'function') el.addEventListener(k.slice(2), v);
        else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
        else el.setAttribute(k, v === true ? '' : String(v));
      });
    }
    for (var i = 2; i < arguments.length; i++) {
      var c = arguments[i];
      if (c === null || c === undefined || c === false) continue;
      if (Array.isArray(c)) c.forEach(function (cc) { if (cc) el.appendChild(cc); });
      else el.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    }
    return el;
  }
  function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); }
  function $(id) { return document.getElementById(id); }

  /* ================= derived model ================= */

  var outAdj = [], inAdj = [];
  for (var i = 0; i < N; i++) { outAdj.push([]); inAdj.push([]); }
  EDGES.forEach(function (e, idx) {
    outAdj[e[0]].push({ t: e[1], via: e[2], e: idx });
    inAdj[e[1]].push({ t: e[0], via: e[2], e: idx });
  });
  var idToIdx = {};
  NODES.forEach(function (n, idx) { idToIdx[n.id] = idx; });

  // Importance percentile: pagerank when meaningful, degree otherwise.
  var scores = NODES.map(function (n, idx) {
    return n.pagerank > 0 ? n.pagerank : (outAdj[idx].length + inAdj[idx].length) * 1e-9;
  });
  var sortedScores = scores.slice().sort(function (a, b) { return a - b; });
  function percentile(idx) {
    if (N <= 1) return 0.5;
    var lo = 0, hi = sortedScores.length - 1, v = scores[idx];
    while (lo < hi) { var mid = (lo + hi) >> 1; if (sortedScores[mid] < v) lo = mid + 1; else hi = mid; }
    return lo / (sortedScores.length - 1);
  }
  var NODE_R = NODES.map(function (_n, idx) { return 6 + 13 * Math.sqrt(percentile(idx)); });
  var rankOrder = NODES.map(function (_n, idx) { return idx; })
    .sort(function (a, b) { return scores[b] - scores[a]; });
  var haystack = NODES.map(function (n) {
    return (n.id + ' ' + (n.file_path || '') + ' ' + n.type).toLowerCase();
  });
  var rankOf = []; rankOrder.forEach(function (idx, r) { rankOf[idx] = r; });

  var cycleMembership = {};
  (ANALYSIS.cycles || []).forEach(function (cycle, ci) {
    cycle.forEach(function (idx) {
      (cycleMembership[idx] = cycleMembership[idx] || []).push(ci);
    });
  });

  var ASSOC_VIAS = { belongs_to: 1, has_many: 1, has_one: 1, has_and_belongs_to_many: 1 };
  var groupByKey = {};
  GROUPS.forEach(function (g) { groupByKey[g.key] = g; });
  function glyphFor(node) { return (groupByKey[node.group] || { glyph: '·' }).glyph; }

  /* ================= state ================= */

  var prefersReduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  // Above this size the full hairball helps nobody: default to the top slice
  // by PageRank (opt-out via the Display checkbox, persisted).
  var LARGE_N = 1200, CAP_K = 600, ERD_CAP = 100;
  var state = {
    view: 'graph',
    selected: null,          // node idx or null
    hovered: null,
    focus: null,             // { node, depth }
    path: null,              // { from, to, nodes: [idx], edges: [eIdx] } | { error }
    groupsOff: {},           // family key -> true when hidden
    viasOff: {},
    showLabels: true,
    showOrphans: true,
    capTop: N > LARGE_N,
    tableSort: { key: 'score', dir: -1 },
    tableFilter: { q: '', type: '' }
  };

  // Filters and display options survive reloads; malformed storage is ignored.
  var UI_KEY = 'woods-explorer-ui:v1';
  (function restoreUi() {
    try {
      var saved = JSON.parse(localStorage.getItem(UI_KEY) || 'null');
      if (!saved) return;
      if (saved.groupsOff) state.groupsOff = saved.groupsOff;
      if (saved.viasOff) state.viasOff = saved.viasOff;
      if (typeof saved.showLabels === 'boolean') state.showLabels = saved.showLabels;
      if (typeof saved.showOrphans === 'boolean') state.showOrphans = saved.showOrphans;
      if (typeof saved.capTop === 'boolean') state.capTop = saved.capTop;
    } catch (e) { /* sandboxed or corrupt — defaults win */ }
  })();
  function persistUi() {
    try {
      localStorage.setItem(UI_KEY, JSON.stringify({
        groupsOff: state.groupsOff, viasOff: state.viasOff,
        showLabels: state.showLabels, showOrphans: state.showOrphans, capTop: state.capTop
      }));
    } catch (e) { /* sandboxed */ }
  }

  function theme() { return document.documentElement.getAttribute('data-theme') || 'light'; }
  function pal() { return PALETTES[theme()]; }
  function colorOf(node) { return pal()[node.group] || pal().other; }
  function cssVar(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }

  // Chrome colors resolved once per theme — getComputedStyle inside per-node
  // draw loops forces style recalcs at 60fps. Invalidated by the theme toggle.
  var chromeCache = null;
  function chrome() {
    return chromeCache || (chromeCache = {
      ink: cssVar('--ink') || '#0b0b0b',
      ink2: cssVar('--ink-2') || '#52514e',
      muted: cssVar('--muted') || '#898781',
      grid: cssVar('--grid') || '#e1e0d9',
      baseline: cssVar('--baseline') || '#c3c2b7',
      surface: cssVar('--surface-1') || '#fcfcfb',
      accent: cssVar('--accent') || '#2a78d6'
    });
  }

  function initTheme() {
    var saved = null;
    try { saved = localStorage.getItem('woods-explorer-theme'); } catch (e) { /* sandboxed */ }
    var dark = saved ? saved === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches;
    document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light');
  }
  initTheme();

  function announce(msg) { $('live-region').textContent = msg; }

  /* Ink color for a glyph inside a colored fill: white or near-black by the
     fill's luminance, so the letter always clears contrast. */
  function glyphInk(hex) {
    var r = parseInt(hex.slice(1, 3), 16) / 255, g = parseInt(hex.slice(3, 5), 16) / 255,
        b = parseInt(hex.slice(5, 7), 16) / 255;
    var lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    return lum > 0.55 ? '#0b0b0b' : '#ffffff';
  }

  /* ================= visibility ================= */

  function nodeTypeVisible(idx) { return !state.groupsOff[NODES[idx].group]; }
  function edgeVisible(e) {
    return !state.viasOff[e[2]] && nodeTypeVisible(e[0]) && nodeTypeVisible(e[1]);
  }

  // Current graph-scene node/edge sets, honoring filters, focus and path.
  function computeScene() {
    var nodeSet = {}, edgeIdx = [];
    if (state.path && state.path.nodes) {
      state.path.nodes.forEach(function (idx) { nodeSet[idx] = true; });
      state.path.edges.forEach(function (ei) { edgeIdx.push(ei); });
      return finishScene(nodeSet, edgeIdx);
    }
    if (state.focus) {
      var frontier = [state.focus.node], seen = {};
      seen[state.focus.node] = 0;
      nodeSet[state.focus.node] = true;
      while (frontier.length) {
        var cur = frontier.shift();
        if (seen[cur] >= state.focus.depth) continue;
        var step = function (adj) {
          adj[cur].forEach(function (a) {
            if (state.viasOff[EDGES[a.e][2]] || !nodeTypeVisible(a.t)) return;
            if (!(a.t in seen)) { seen[a.t] = seen[cur] + 1; nodeSet[a.t] = true; frontier.push(a.t); }
          });
        };
        step(outAdj); step(inAdj);
      }
      EDGES.forEach(function (e, ei) {
        if (nodeSet[e[0]] && nodeSet[e[1]] && edgeVisible(e)) edgeIdx.push(ei);
      });
      return finishScene(nodeSet, edgeIdx);
    }
    if (state.capTop && N > LARGE_N) {
      var kept = 0;
      for (var r = 0; r < rankOrder.length && kept < CAP_K; r++) {
        if (nodeTypeVisible(rankOrder[r])) { nodeSet[rankOrder[r]] = true; kept++; }
      }
      if (state.selected !== null && nodeTypeVisible(state.selected)) nodeSet[state.selected] = true;
    } else {
      for (var idx = 0; idx < N; idx++) if (nodeTypeVisible(idx)) nodeSet[idx] = true;
    }
    EDGES.forEach(function (e, ei) { if (edgeVisible(e) && nodeSet[e[0]] && nodeSet[e[1]]) edgeIdx.push(ei); });
    if (!state.showOrphans) {
      var connected = {};
      edgeIdx.forEach(function (ei) { connected[EDGES[ei][0]] = true; connected[EDGES[ei][1]] = true; });
      Object.keys(nodeSet).forEach(function (k) { if (!connected[k]) delete nodeSet[k]; });
    }
    return finishScene(nodeSet, edgeIdx);
  }
  function finishScene(nodeSet, edgeIdx) {
    var nodes = Object.keys(nodeSet).map(Number).sort(function (a, b) { return a - b; });
    return { nodes: nodes, edges: edgeIdx, nodeSet: nodeSet };
  }

  /* ================= force simulation ================= */

  function mulberry32(seed) {
    return function () {
      seed |= 0; seed = (seed + 0x6D2B79F5) | 0;
      var t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  // Deterministic initial position: family clusters on a ring.
  var groupAngle = {};
  GROUPS.forEach(function (g, gi) { groupAngle[g.key] = (gi / GROUPS.length) * Math.PI * 2; });
  var basePos = NODES.map(function (n, idx) {
    var rand = mulberry32(idx * 2654435761 + 1);
    var ang = (groupAngle[n.group] || 0) + (rand() - 0.5) * 0.9;
    var rad = 220 + rand() * 240;
    return { x: Math.cos(ang) * rad, y: Math.sin(ang) * rad };
  });

  function Quadtree(pts) {
    // pts: [{x, y, m}] — builds a Barnes-Hut tree
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    pts.forEach(function (p) {
      if (p.x < minX) minX = p.x; if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y; if (p.y > maxY) maxY = p.y;
    });
    var size = Math.max(maxX - minX, maxY - minY, 1);
    var root = { x: minX, y: minY, s: size, m: 0, cx: 0, cy: 0, kids: null, pt: null };
    function insert(node, p) {
      while (true) {
        node.m += p.m; node.cx += p.x * p.m; node.cy += p.y * p.m;
        if (!node.kids && !node.pt) { node.pt = p; return; }
        if (!node.kids) {
          if (node.s < 1e-4) return; // coincident points
          node.kids = [null, null, null, null];
          var old = node.pt; node.pt = null;
          insertChild(node, old);
        }
        node = childFor(node, p);
      }
    }
    function childFor(node, p) {
      var half = node.s / 2;
      var qx = p.x >= node.x + half ? 1 : 0, qy = p.y >= node.y + half ? 1 : 0;
      var qi = qy * 2 + qx;
      if (!node.kids[qi]) {
        node.kids[qi] = { x: node.x + qx * half, y: node.y + qy * half, s: half, m: 0, cx: 0, cy: 0, kids: null, pt: null };
      }
      return node.kids[qi];
    }
    function insertChild(node, p) {
      var child = childFor(node, p);
      child.m += p.m; child.cx += p.x * p.m; child.cy += p.y * p.m; child.pt = p;
    }
    pts.forEach(function (p) { insert(root, p); });
    return root;
  }

  function Sim(sceneNodes, sceneEdges, radii) {
    var self = {};
    var pts = sceneNodes.map(function (idx) {
      var prev = layoutPos[idx];
      return {
        idx: idx,
        x: prev ? prev.x : basePos[idx].x,
        y: prev ? prev.y : basePos[idx].y,
        vx: 0, vy: 0, m: 1, r: radii[idx], fixed: false
      };
    });
    var byIdx = {}; pts.forEach(function (p) { byIdx[p.idx] = p; });
    var springs = sceneEdges.map(function (ei) {
      var e = EDGES[ei];
      return { a: byIdx[e[0]], b: byIdx[e[1]] };
    }).filter(function (s) { return s.a && s.b && s.a !== s.b; });
    var alpha = 1;
    var theta2 = 0.85 * 0.85;

    self.pts = pts; self.byIdx = byIdx;
    self.alpha = function () { return alpha; };
    self.reheat = function (a) { alpha = Math.max(alpha, a); };

    var REPULSE = 60;
    self.tick = function () {
      var qt = Quadtree(pts);
      pts.forEach(function (p) {
        if (p.fixed) return;
        // Barnes-Hut repulsion: v += d̂ · REPULSE·m·alpha / d  (1/d falloff)
        var stack = [qt];
        while (stack.length) {
          var node = stack.pop();
          if (!node || node.m === 0) continue;
          var cx = node.cx / node.m, cy = node.cy / node.m;
          var dx = p.x - cx, dy = p.y - cy;
          var d2 = dx * dx + dy * dy;
          if (node.pt === p && !node.kids) continue;
          if (node.kids && (node.s * node.s) / Math.max(d2, 1) > theta2) {
            stack.push(node.kids[0], node.kids[1], node.kids[2], node.kids[3]);
            continue;
          }
          if (d2 < 1) { d2 = 1; dx = (p.idx % 7) - 3 || 1; dy = ((p.idx * 13) % 7) - 3 || -1; }
          var f = (REPULSE * node.m * alpha) / d2;
          p.vx += dx * f;
          p.vy += dy * f;
        }
        // centering gravity
        p.vx -= p.x * 0.008 * alpha;
        p.vy -= p.y * 0.008 * alpha;
      });
      // springs
      springs.forEach(function (s) {
        var rest = 60 + s.a.r + s.b.r;
        var dx = s.b.x - s.a.x, dy = s.b.y - s.a.y;
        var d = Math.sqrt(dx * dx + dy * dy) || 1;
        var f = ((d - rest) / d) * 0.2 * alpha;
        var fx = dx * f, fy = dy * f;
        if (!s.a.fixed) { s.a.vx += fx; s.a.vy += fy; }
        if (!s.b.fixed) { s.b.vx -= fx; s.b.vy -= fy; }
      });
      // collision (grid-bucketed)
      collide(pts);
      pts.forEach(function (p) {
        if (p.fixed) { p.vx = 0; p.vy = 0; return; }
        p.vx *= 0.62; p.vy *= 0.62;
        var vmax = 24;
        if (p.vx > vmax) p.vx = vmax; if (p.vx < -vmax) p.vx = -vmax;
        if (p.vy > vmax) p.vy = vmax; if (p.vy < -vmax) p.vy = -vmax;
        p.x += p.vx; p.y += p.vy;
      });
      alpha *= 0.977;
      pts.forEach(function (p) { layoutPos[p.idx] = { x: p.x, y: p.y }; });
      return alpha > 0.02;
    };

    function collide(list) {
      var maxR = 0;
      list.forEach(function (p) { if (p.r > maxR) maxR = p.r; });
      var cell = Math.max(60, maxR * 2), grid = {};
      list.forEach(function (p) {
        var key = Math.floor(p.x / cell) + ':' + Math.floor(p.y / cell);
        (grid[key] = grid[key] || []).push(p);
      });
      list.forEach(function (p) {
        var gx = Math.floor(p.x / cell), gy = Math.floor(p.y / cell);
        for (var ox = -1; ox <= 1; ox++) {
          for (var oy = -1; oy <= 1; oy++) {
            var bucket = grid[(gx + ox) + ':' + (gy + oy)];
            if (!bucket) continue;
            bucket.forEach(function (q) {
              if (q === p) return;
              var dx = q.x - p.x, dy = q.y - p.y;
              var d = Math.sqrt(dx * dx + dy * dy);
              var min = p.r + q.r + 4;
              if (d > 0 && d < min) {
                var push = ((min - d) / d) * 0.5;
                if (!p.fixed) { p.x -= dx * push; p.y -= dy * push; }
                if (!q.fixed) { q.x += dx * push; q.y += dy * push; }
              }
            });
          }
        }
      });
    }

    return self;
  }
  var layoutPos = {}; // node idx -> {x, y}, persists across scene rebuilds

  /* ================= canvas renderer ================= */

  var canvas = $('canvas'), ctx = canvas.getContext('2d');
  var view = { x: 0, y: 0, k: 1 }; // world -> screen: s = (w * k) + offset
  var scene = null, sim = null, running = false;
  var autoFit = true; // track the settling layout until the user pans/zooms
  var erdBoxes = null; // idx -> {w, h, cols} in ERD mode
  var pathLine = null;

  function isCanvasView() { return state.view === 'graph' || state.view === 'erd'; }

  function resize() {
    var rect = canvas.parentElement.getBoundingClientRect();
    var dpr = window.devicePixelRatio || 1;
    canvas.width = Math.max(1, Math.round(rect.width * dpr));
    canvas.height = Math.max(1, Math.round(rect.height * dpr));
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    draw();
  }

  function toScreen(x, y) { return [x * view.k + view.x, y * view.k + view.y]; }
  function toWorld(sx, sy) { return [(sx - view.x) / view.k, (sy - view.y) / view.k]; }

  function setBanner(text) {
    var banner = $('canvas-banner');
    banner.hidden = !text;
    banner.textContent = text || '';
  }

  function rebuildScene(reheat) {
    if (state.view === 'erd') { rebuildErd(); return; }
    setBanner('');
    scene = computeScene();
    erdBoxes = null;
    if (state.path && state.path.nodes) { layoutPath(); sim = null; drawLoop(); return; }
    // Nodes with no edge in this scene don't join the simulation — they'd
    // repel forever and drag the camera out. They sit in a static grid block
    // beside the connected layout instead.
    var connected = {};
    scene.edges.forEach(function (ei) { connected[EDGES[ei][0]] = true; connected[EDGES[ei][1]] = true; });
    var simNodes = [], loose = [];
    scene.nodes.forEach(function (idx) { (connected[idx] ? simNodes : loose).push(idx); });
    placeLooseGrid(loose, simNodes.length);
    sim = Sim(simNodes, scene.edges, NODE_R);
    if (reheat !== false) sim.reheat(1);
    autoFit = true;
    $('empty-note').hidden = scene.nodes.length > 0;
    if (scene.nodes.length === 0) {
      $('empty-note').textContent = 'Nothing to show — enable more families in the sidebar.';
    }
    if (prefersReduced) {
      var guard = 0;
      while (sim.tick() && guard++ < 400) { /* settle synchronously */ }
      fit(); draw();
    } else {
      drawLoop();
      scheduleFit();
    }
    updateStatus();
  }

  // Path scene: fixed left-to-right layout, no simulation.
  function layoutPath() {
    var nodes = state.path.nodes;
    var gap = 170;
    nodes.forEach(function (idx, i) {
      layoutPos[idx] = { x: i * gap - ((nodes.length - 1) * gap) / 2, y: 0 };
    });
    fit();
    $('empty-note').hidden = true;
    updateStatus();
  }

  var fitTimer = null;
  function scheduleFit() {
    if (fitTimer) clearTimeout(fitTimer);
    fitTimer = setTimeout(fit, 600);
  }

  // Deterministic grid block for scene-orphans, to the right of the
  // simulated cluster (whose radius grows with node count).
  function placeLooseGrid(loose, connectedCount) {
    if (!loose.length) return;
    var startX = Math.sqrt(Math.max(connectedCount, 1)) * 46 + 220;
    var cols = Math.max(1, Math.ceil(Math.sqrt(loose.length)));
    var cell = 52;
    loose.forEach(function (idx, i) {
      layoutPos[idx] = {
        x: startX + (i % cols) * cell,
        y: ((i / cols) | 0) * cell - (Math.ceil(loose.length / cols) * cell) / 2
      };
    });
  }

  function fit() {
    var idxs = scene ? scene.nodes : [];
    if (!idxs.length) return;
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    idxs.forEach(function (idx) {
      var p = layoutPos[idx]; if (!p) return;
      var r = boxRadius(idx);
      if (p.x - r < minX) minX = p.x - r; if (p.x + r > maxX) maxX = p.x + r;
      if (p.y - r < minY) minY = p.y - r; if (p.y + r > maxY) maxY = p.y + r;
    });
    var rect = canvas.parentElement.getBoundingClientRect();
    var pad = 60;
    var kx = (rect.width - pad * 2) / Math.max(maxX - minX, 40);
    var ky = (rect.height - pad * 2) / Math.max(maxY - minY, 40);
    view.k = Math.min(Math.max(Math.min(kx, ky), 0.08), 1.6);
    view.x = rect.width / 2 - ((minX + maxX) / 2) * view.k;
    view.y = rect.height / 2 - ((minY + maxY) / 2) * view.k;
    draw();
  }

  function boxRadius(idx) {
    if (erdBoxes && erdBoxes[idx]) {
      var b = erdBoxes[idx];
      return Math.sqrt(b.w * b.w + b.h * b.h) / 2;
    }
    return NODE_R[idx];
  }

  function drawLoop() {
    if (running) return;
    running = true;
    (function frame() {
      var more = sim ? sim.tick() : false;
      if (autoFit) fit(); else draw();
      if (more && isCanvasView()) requestAnimationFrame(frame);
      else { running = false; if (autoFit) { fit(); autoFit = false; } }
    })();
  }

  function neighborSet(idx) {
    var set = {};
    outAdj[idx].forEach(function (a) { set[a.t] = true; });
    inAdj[idx].forEach(function (a) { set[a.t] = true; });
    return set;
  }

  function draw() {
    if (!isCanvasView() || !scene) return;
    var rect = canvas.parentElement.getBoundingClientRect();
    ctx.clearRect(0, 0, rect.width, rect.height);
    var focusIdx = state.hovered !== null ? state.hovered : state.selected;
    var neigh = focusIdx !== null ? neighborSet(focusIdx) : null;
    var inkBase = chrome().baseline;
    var surface = chrome().surface;
    var pathEdges = state.path && state.path.edges ? state.path.edges : null;

    // edges
    scene.edges.forEach(function (ei) {
      var e = EDGES[ei];
      var a = layoutPos[e[0]], b = layoutPos[e[1]];
      if (!a || !b) return;
      var incident = focusIdx !== null && (e[0] === focusIdx || e[1] === focusIdx);
      var onPath = pathEdges && pathEdges.indexOf(ei) >= 0;
      var dim = focusIdx !== null && !incident && !onPath;
      ctx.globalAlpha = onPath ? 0.95 : incident ? 0.9 : dim ? 0.08 : 0.3;
      ctx.strokeStyle = incident || onPath ? colorOf(NODES[e[0]]) : inkBase;
      ctx.lineWidth = onPath ? 2.2 : incident ? 1.6 : 1;
      drawEdge(e, ei);
    });
    ctx.globalAlpha = 1;

    // In ERD mode the association macro rides the edge (small graphs only)
    if (erdBoxes && scene.edges.length <= 60 && view.k >= 0.35) {
      ctx.font = '10.5px system-ui, sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      scene.edges.forEach(function (ei) {
        var e = EDGES[ei];
        if (e[0] === e[1]) return;
        var mid = edgeMidpoint(e, ei);
        var incident = focusIdx !== null && (e[0] === focusIdx || e[1] === focusIdx);
        ctx.globalAlpha = focusIdx !== null && !incident ? 0.25 : 1;
        ctx.lineWidth = 3;
        ctx.strokeStyle = surface;
        ctx.strokeText(e[2], mid[0], mid[1]);
        ctx.fillStyle = chrome().muted;
        ctx.fillText(e[2], mid[0], mid[1]);
      });
      ctx.globalAlpha = 1;
    }

    // nodes: draw big first so small stay clickable on top
    var order = scene.nodes.slice().sort(function (a, b) { return NODE_R[b] - NODE_R[a]; });
    order.forEach(function (idx) {
      var p = layoutPos[idx]; if (!p) return;
      var s = toScreen(p.x, p.y);
      if (erdBoxes && erdBoxes[idx]) { drawErdBox(idx, s, focusIdx, neigh, surface); return; }
      var r = NODE_R[idx] * view.k;
      var isFocus = idx === focusIdx;
      var related = neigh && neigh[idx];
      var onPath = state.path && state.path.nodes && state.path.nodes.indexOf(idx) >= 0;
      var dim = focusIdx !== null && !isFocus && !related && !onPath;
      ctx.globalAlpha = dim ? 0.3 : 1;
      var color = colorOf(NODES[idx]);
      ctx.beginPath();
      ctx.arc(s[0], s[1], r, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();
      // 2px surface ring keeps overlapping nodes legible
      ctx.lineWidth = 2;
      ctx.strokeStyle = surface;
      ctx.stroke();
      if (idx === state.selected) {
        ctx.beginPath();
        ctx.arc(s[0], s[1], r + 3.5, 0, Math.PI * 2);
        ctx.lineWidth = 2.5;
        ctx.strokeStyle = chrome().accent;
        ctx.stroke();
      }
      // family glyph (secondary encoding — identity never rides on color alone)
      if (r >= 6.5) {
        ctx.fillStyle = glyphInk(color);
        ctx.font = '700 ' + Math.max(8, Math.min(12, r * 0.9)) + 'px system-ui, sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(glyphFor(NODES[idx]), s[0], s[1] + 0.5);
      }
      ctx.globalAlpha = 1;
    });

    drawLabels(focusIdx, neigh, surface);
  }

  // One source of truth for edge curvature: endpoints + control point.
  function edgeControl(e, ei) {
    var a = layoutPos[e[0]], b = layoutPos[e[1]];
    var sa = toScreen(a.x, a.y), sb = toScreen(b.x, b.y);
    var dx = sb[0] - sa[0], dy = sb[1] - sa[1];
    var bend = 0.08 + (ei % 3) * 0.05;
    return { sa: sa, sb: sb, mx: (sa[0] + sb[0]) / 2 - dy * bend, my: (sa[1] + sb[1]) / 2 + dx * bend };
  }

  function edgeMidpoint(e, ei) {
    var c = edgeControl(e, ei);
    // quadratic Bézier at t=0.5
    return [0.25 * c.sa[0] + 0.5 * c.mx + 0.25 * c.sb[0], 0.25 * c.sa[1] + 0.5 * c.my + 0.25 * c.sb[1]];
  }

  function drawEdge(e, ei) {
    var a = layoutPos[e[0]], b = layoutPos[e[1]];
    var sa = toScreen(a.x, a.y), sb = toScreen(b.x, b.y);
    if (e[0] === e[1]) { // self reference: small loop
      var r = NODE_R[e[0]] * view.k;
      ctx.beginPath();
      ctx.arc(sa[0] + r, sa[1] - r, r * 0.8, 0, Math.PI * 2);
      ctx.stroke();
      return;
    }
    // slight curvature; parallel edges bend progressively
    var c = edgeControl(e, ei);
    var mx = c.mx, my = c.my;
    ctx.beginPath();
    ctx.moveTo(sa[0], sa[1]);
    ctx.quadraticCurveTo(mx, my, sb[0], sb[1]);
    ctx.stroke();
    // arrowhead at target, offset by node radius
    var tr = boxRadius(e[1]) * view.k + 3;
    var tx = sb[0] - mx, ty = sb[1] - my;
    var td = Math.sqrt(tx * tx + ty * ty) || 1;
    var ax = sb[0] - (tx / td) * tr, ay = sb[1] - (ty / td) * tr;
    var size = Math.min(6, 3 + view.k * 2);
    ctx.beginPath();
    ctx.moveTo(ax, ay);
    ctx.lineTo(ax - (tx / td) * size - (ty / td) * size * 0.5, ay - (ty / td) * size + (tx / td) * size * 0.5);
    ctx.lineTo(ax - (tx / td) * size + (ty / td) * size * 0.5, ay - (ty / td) * size - (tx / td) * size * 0.5);
    ctx.closePath();
    ctx.fillStyle = ctx.strokeStyle;
    ctx.fill();
  }

  function drawLabels(focusIdx, neigh, surface) {
    if (erdBoxes) return; // boxes carry their own titles
    var ink = chrome().ink;
    var labelBudget = view.k > 1.2 ? 400 : view.k > 0.6 ? 90 : 30;
    var shown = 0;
    var placed = []; // screen-space rects already used; later (less important) labels skip on overlap
    ctx.font = '550 11px system-ui, sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    var pathNodes = state.path && state.path.nodes;
    rankOrder.forEach(function (idx) {
      if (!scene.nodeSet[idx]) return;
      // Only anchor nodes bypass occlusion; a selected hub with 300
      // neighbors must not smear 300 overlapping labels into a text blob.
      var anchor = idx === focusIdx || idx === state.selected ||
                   (pathNodes && pathNodes.indexOf(idx) >= 0);
      var must = anchor || (neigh && neigh[idx]);
      if (!must) {
        if (!state.showLabels) return;
        if (shown >= labelBudget) return;
      }
      var p = layoutPos[idx]; if (!p) return;
      var s = toScreen(p.x, p.y);
      var label = NODES[idx].label;
      var w = ctx.measureText(label).width;
      var ly = s[1] + Math.max(NODE_R[idx] * view.k, 3) + 2;
      var rect = { x: s[0] - w / 2 - 2, y: ly, w: w + 4, h: 15 };
      if (!anchor && placed.some(function (r) { return overlaps(r, rect); })) return;
      placed.push(rect);
      ctx.lineWidth = 3;
      ctx.strokeStyle = surface;
      ctx.strokeText(label, s[0], ly + 2);
      ctx.fillStyle = ink;
      ctx.fillText(label, s[0], ly + 2);
      shown++;
    });
  }

  function overlaps(a, b) {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
  }

  /* ================= ERD mode ================= */

  function rebuildErd() {
    var allModels = [];
    NODES.forEach(function (n, idx) { if (n.type === 'model') allModels.push(idx); });
    var modelIdxs = allModels;
    var note = '';
    if (state.focus !== null && NODES[state.focus.node] && NODES[state.focus.node].type === 'model') {
      // Focus mode: the selected model's association neighborhood only.
      modelIdxs = erdNeighborhood(state.focus.node, state.focus.depth);
      $('focus-section').hidden = false;
    } else if (allModels.length > ERD_CAP + 20) {
      // A wall of hundreds of schema boxes helps nobody — show the most
      // connected slice and say so; Focus (or search) reaches the rest.
      var ranked = allModels.slice().sort(function (a, b) { return rankOf[a] - rankOf[b]; });
      modelIdxs = ranked.slice(0, ERD_CAP);
      if (state.selected !== null && NODES[state.selected].type === 'model' &&
          modelIdxs.indexOf(state.selected) < 0) modelIdxs.push(state.selected);
      note = 'Showing the ' + ERD_CAP + ' most connected of ' + allModels.length +
             ' models — select a model and Focus neighborhood to see the rest.';
    }
    var inSet = {};
    modelIdxs.forEach(function (idx) { inSet[idx] = true; });
    var edgeIdx = [];
    EDGES.forEach(function (e, ei) {
      if (ASSOC_VIAS[e[2]] && inSet[e[0]] && inSet[e[1]]) edgeIdx.push(ei);
    });
    scene = { nodes: modelIdxs, edges: edgeIdx, nodeSet: inSet };
    $('empty-note').hidden = true;
    setBanner(note);

    erdBoxes = {};
    ctx.font = '550 12px system-ui, sans-serif';
    modelIdxs.forEach(function (idx) {
      var cols = ((NODES[idx].facts || {}).columns || []).slice(0, 7);
      var more = Math.max(0, ((NODES[idx].facts || {}).columns_total || cols.length) - cols.length);
      var w = ctx.measureText(NODES[idx].label).width + 44;
      cols.forEach(function (c) {
        w = Math.max(w, ctx.measureText((c.name || '') + '  ' + (c.type || '')).width + 26);
      });
      erdBoxes[idx] = {
        w: Math.min(Math.max(w, 130), 250),
        h: 30 + cols.length * 16 + (more ? 16 : 0) + 8,
        cols: cols, more: more
      };
    });
    var radii = {};
    modelIdxs.forEach(function (idx) {
      var b = erdBoxes[idx];
      radii[idx] = Math.sqrt(b.w * b.w + b.h * b.h) / 2 + 20;
    });
    if (!modelIdxs.length) {
      $('empty-note').hidden = false;
      $('empty-note').textContent = 'No models in this extraction.';
    }
    sim = Sim(modelIdxs, edgeIdx, radii);
    sim.reheat(1);
    autoFit = true;
    if (prefersReduced) {
      var guard = 0;
      while (sim.tick() && guard++ < 400) { /* settle synchronously */ }
      fit(); draw();
    } else { drawLoop(); scheduleFit(); }
    updateStatus();
  }

  // BFS over model-to-model association edges for ERD focus mode.
  function erdNeighborhood(start, depth) {
    var seen = {}; seen[start] = 0;
    var queue = [start], result = [start];
    while (queue.length) {
      var cur = queue.shift();
      if (seen[cur] >= depth) continue;
      var visit = function (adj) {
        adj[cur].forEach(function (a) {
          if (!ASSOC_VIAS[a.via] || NODES[a.t].type !== 'model' || a.t in seen) return;
          seen[a.t] = seen[cur] + 1;
          result.push(a.t);
          queue.push(a.t);
        });
      };
      visit(outAdj); visit(inAdj);
    }
    return result;
  }

  function drawErdBox(idx, s, focusIdx, neigh, surface) {
    var b = erdBoxes[idx];
    var w = b.w * view.k, hh = b.h * view.k;
    var x = s[0] - w / 2, y = s[1] - hh / 2;
    var color = colorOf(NODES[idx]);
    var dim = focusIdx !== null && idx !== focusIdx && !(neigh && neigh[idx]);
    ctx.globalAlpha = dim ? 0.5 : 1;
    ctx.beginPath();
    roundRect(x, y, w, hh, 8 * view.k);
    ctx.fillStyle = surface;
    ctx.fill();
    ctx.lineWidth = idx === state.selected ? 2.4 : 1.2;
    ctx.strokeStyle = idx === state.selected ? chrome().accent : chrome().baseline;
    ctx.stroke();
    if (view.k < 0.35) {
      // Too small for column text — but a box should never render empty.
      // Draw the model name at a fixed screen size with a family dot.
      ctx.beginPath();
      ctx.arc(s[0] - w / 2 + 8, s[1], 3.5, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();
      ctx.fillStyle = chrome().ink;
      ctx.font = '600 10.5px system-ui, sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      var name = NODES[idx].label;
      var maxW = w - 22;
      while (name.length > 3 && ctx.measureText(name).width > maxW) name = name.slice(0, -2);
      if (name !== NODES[idx].label) name += '…';
      ctx.fillText(name, s[0] + 5, s[1]);
      ctx.globalAlpha = 1;
      return;
    }
    // title row: family dot + name in ink (text never wears the data color)
    ctx.beginPath();
    ctx.arc(x + 13 * view.k, y + 14 * view.k, 4.5 * view.k, 0, Math.PI * 2);
    ctx.fillStyle = color;
    ctx.fill();
    ctx.fillStyle = chrome().ink;
    ctx.font = '650 ' + 12 * view.k + 'px system-ui, sans-serif';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillText(NODES[idx].label, x + 24 * view.k, y + 14.5 * view.k);
    ctx.strokeStyle = chrome().grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(x, y + 26 * view.k);
    ctx.lineTo(x + w, y + 26 * view.k);
    ctx.stroke();
    ctx.font = 11 * view.k + 'px system-ui, sans-serif';
    b.cols.forEach(function (c, ci) {
      var yy = y + (34 + ci * 16) * view.k + 5 * view.k;
      ctx.fillStyle = chrome().ink2;
      ctx.fillText(c.name || '', x + 12 * view.k, yy);
      ctx.fillStyle = chrome().muted;
      ctx.textAlign = 'right';
      ctx.fillText(c.type || '', x + w - 10 * view.k, yy);
      ctx.textAlign = 'left';
    });
    if (b.more) {
      ctx.fillStyle = chrome().muted;
      ctx.fillText('+' + b.more + ' more…', x + 12 * view.k, y + (34 + b.cols.length * 16) * view.k + 5 * view.k);
    }
    ctx.globalAlpha = 1;
  }

  function roundRect(x, y, w, hh, r) {
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + hh, r);
    ctx.arcTo(x + w, y + hh, x, y + hh, r);
    ctx.arcTo(x, y + hh, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  /* ================= canvas interactions ================= */

  var pointer = { down: false, dragNode: null, panned: false, sx: 0, sy: 0, vx0: 0, vy0: 0 };
  var tooltip = h('div', { id: 'tooltip', hidden: true, role: 'tooltip' });
  document.body.appendChild(tooltip);

  function hitTest(sx, sy) {
    if (!scene) return null;
    var w = toWorld(sx, sy);
    var best = null, bestD = Infinity;
    scene.nodes.forEach(function (idx) {
      var p = layoutPos[idx]; if (!p) return;
      if (erdBoxes && erdBoxes[idx]) {
        var b = erdBoxes[idx];
        if (Math.abs(w[0] - p.x) <= b.w / 2 + 4 && Math.abs(w[1] - p.y) <= b.h / 2 + 4) {
          var dd = Math.abs(w[0] - p.x) + Math.abs(w[1] - p.y);
          if (dd < bestD) { bestD = dd; best = idx; }
        }
        return;
      }
      var dx = w[0] - p.x, dy = w[1] - p.y;
      var d = Math.sqrt(dx * dx + dy * dy);
      var hit = Math.max(NODE_R[idx] + 4, 12 / view.k); // ≥24px hit target, covers min screen radius
      if (d <= hit && d < bestD) { bestD = d; best = idx; }
    });
    return best;
  }

  canvas.addEventListener('pointerdown', function (ev) {
    autoFit = false;
    canvas.setPointerCapture(ev.pointerId);
    pointer.down = true; pointer.panned = false;
    pointer.sx = ev.clientX; pointer.sy = ev.clientY;
    pointer.vx0 = view.x; pointer.vy0 = view.y;
    var idx = hitTest(ev.offsetX, ev.offsetY);
    pointer.dragNode = idx;
    if (idx !== null && sim && sim.byIdx[idx]) sim.byIdx[idx].fixed = true;
  });

  canvas.addEventListener('pointermove', function (ev) {
    if (pointer.down) {
      var dx = ev.clientX - pointer.sx, dy = ev.clientY - pointer.sy;
      if (Math.abs(dx) + Math.abs(dy) > 3) pointer.panned = true;
      if (pointer.dragNode !== null && sim && sim.byIdx[pointer.dragNode]) {
        var wpt = toWorld(ev.offsetX, ev.offsetY);
        var p = sim.byIdx[pointer.dragNode];
        p.x = wpt[0]; p.y = wpt[1];
        layoutPos[pointer.dragNode] = { x: p.x, y: p.y };
        sim.reheat(0.25);
        drawLoop();
      } else {
        view.x = pointer.vx0 + dx; view.y = pointer.vy0 + dy;
        draw();
      }
      return;
    }
    var idx = hitTest(ev.offsetX, ev.offsetY);
    if (idx !== state.hovered) {
      state.hovered = idx;
      canvas.style.cursor = idx !== null ? 'pointer' : 'default';
      showTooltip(idx, ev.clientX, ev.clientY);
      draw();
    } else if (idx !== null) {
      positionTooltip(ev.clientX, ev.clientY);
    }
  });

  canvas.addEventListener('pointerup', function (ev) {
    if (pointer.dragNode !== null && sim && sim.byIdx[pointer.dragNode]) {
      sim.byIdx[pointer.dragNode].fixed = false;
    }
    if (!pointer.panned) {
      var idx = hitTest(ev.offsetX, ev.offsetY);
      selectNode(idx, { openDetail: idx !== null });
    }
    pointer.down = false; pointer.dragNode = null;
  });

  canvas.addEventListener('pointerleave', function () {
    state.hovered = null;
    tooltip.hidden = true;
    draw();
  });

  canvas.addEventListener('dblclick', function (ev) {
    var idx = hitTest(ev.offsetX, ev.offsetY);
    if (idx !== null) setFocus(idx);
  });

  canvas.addEventListener('wheel', function (ev) {
    autoFit = false;
    ev.preventDefault();
    var factor = Math.exp(-ev.deltaY * 0.0016);
    zoomAt(ev.offsetX, ev.offsetY, factor);
  }, { passive: false });

  function zoomAt(sx, sy, factor) {
    var k2 = Math.min(Math.max(view.k * factor, 0.08), 6);
    var w = toWorld(sx, sy);
    view.k = k2;
    view.x = sx - w[0] * k2;
    view.y = sy - w[1] * k2;
    draw();
  }

  $('zoom-in').addEventListener('click', function () {
    var r = canvas.parentElement.getBoundingClientRect();
    zoomAt(r.width / 2, r.height / 2, 1.35);
  });
  $('zoom-out').addEventListener('click', function () {
    var r = canvas.parentElement.getBoundingClientRect();
    zoomAt(r.width / 2, r.height / 2, 1 / 1.35);
  });
  $('zoom-fit').addEventListener('click', fit);

  function showTooltip(idx, cx, cy) {
    if (idx === null) { tooltip.hidden = true; return; }
    clear(tooltip);
    var n = NODES[idx];
    tooltip.appendChild(h('div', { class: 'tt-title' },
      h('span', { class: 'tt-dot', style: { background: colorOf(n) } }),
      h('span', { text: n.id })));
    tooltip.appendChild(h('div', { class: 'tt-sub', text: n.type + (n.summary && n.summary !== n.type ? ' · ' + n.summary : '') }));
    tooltip.appendChild(h('div', { class: 'tt-via', text: '→ ' + n.out + ' dependencies · ← ' + n.in + ' dependents' }));
    tooltip.hidden = false;
    positionTooltip(cx, cy);
  }
  function positionTooltip(cx, cy) {
    var pad = 14;
    tooltip.style.left = Math.min(cx + pad, window.innerWidth - tooltip.offsetWidth - 8) + 'px';
    tooltip.style.top = Math.min(cy + pad, window.innerHeight - tooltip.offsetHeight - 8) + 'px';
  }

  // Keyboard navigation on the canvas
  canvas.addEventListener('keydown', function (ev) {
    if (!scene || !scene.nodes.length) return;
    var dirs = { ArrowRight: 0, ArrowDown: Math.PI / 2, ArrowLeft: Math.PI, ArrowUp: -Math.PI / 2 };
    if (ev.key in dirs) {
      ev.preventDefault();
      moveSelection(dirs[ev.key]);
    } else if (ev.key === 'Enter' && state.selected !== null) {
      openDetail(state.selected);
    } else if (ev.key === 'Escape') {
      if (state.path) clearPath();
      else if (state.focus) clearFocus();
      else selectNode(null, {});
    } else if (ev.key === 'f' && state.selected !== null) {
      setFocus(state.selected);
    }
  });

  function moveSelection(angle) {
    var from = state.selected !== null && scene.nodeSet[state.selected]
      ? state.selected
      : scene.nodes.slice().sort(function (a, b) { return rankOf[a] - rankOf[b]; })[0];
    if (state.selected === null) { selectNode(from, { openDetail: false, center: true }); return; }
    var fp = layoutPos[from];
    var best = null, bestScore = Infinity;
    scene.nodes.forEach(function (idx) {
      if (idx === from) return;
      var p = layoutPos[idx]; if (!p) return;
      var dx = p.x - fp.x, dy = p.y - fp.y;
      var d = Math.sqrt(dx * dx + dy * dy);
      var diff = Math.abs(normAngle(Math.atan2(dy, dx) - angle));
      if (diff > Math.PI / 2.5) return;
      var s = d * (1 + diff * 2);
      if (s < bestScore) { bestScore = s; best = idx; }
    });
    if (best !== null) selectNode(best, { openDetail: false, center: true });
  }
  function normAngle(a) { while (a > Math.PI) a -= Math.PI * 2; while (a < -Math.PI) a += Math.PI * 2; return a; }

  /* ================= selection / focus / detail ================= */

  function selectNode(idx, opts) {
    state.selected = idx;
    if (idx !== null) {
      // openDetail:false keeps arrow-key navigation lightweight — the panel
      // opens on Enter/click, but if it's already open its content follows.
      if (opts.openDetail !== false || !$('detail').hidden) openDetail(idx);
      if (opts.center) centerOn(idx);
      var n = NODES[idx];
      announce('Selected ' + n.id + ', ' + n.type + (n.summary && n.summary !== n.type ? ', ' + n.summary : ''));
    } else {
      $('detail').hidden = true;
    }
    syncHash();
    draw();
  }

  function centerOn(idx) {
    var p = layoutPos[idx]; if (!p) return;
    var rect = canvas.parentElement.getBoundingClientRect();
    view.x = rect.width / 2 - p.x * view.k;
    view.y = rect.height / 2 - p.y * view.k;
    draw();
  }

  function setFocus(idx) {
    state.focus = { node: idx, depth: parseInt($('focus-depth').value, 10) || 1 };
    state.path = null;
    $('focus-section').hidden = false;
    clear($('focus-info'));
    $('focus-info').appendChild(h('span', { text: 'Neighborhood of ' }));
    $('focus-info').appendChild(h('strong', { text: NODES[idx].id }));
    var stayInErd = state.view === 'erd' && NODES[idx].type === 'model';
    if (state.view !== 'graph' && !stayInErd) switchView('graph', { keepFocus: true });
    else rebuildScene();
    announce('Focused on the neighborhood of ' + NODES[idx].id);
  }

  function clearFocus() {
    state.focus = null;
    $('focus-section').hidden = true;
    rebuildScene();
  }

  $('focus-depth').addEventListener('input', function () {
    $('focus-depth-value').textContent = this.value;
    if (state.focus) { state.focus.depth = parseInt(this.value, 10); rebuildScene(); }
  });
  $('focus-clear').addEventListener('click', clearFocus);

  function openDetail(idx) {
    var n = NODES[idx];
    var body = $('detail-body');
    clear(body);
    var color = colorOf(n);

    var head = h('div', { class: 'd-head' },
      h('span', { class: 'd-glyph', style: { background: color, color: glyphInk(color) }, text: glyphFor(n) }),
      h('div', {},
        h('div', { class: 'd-title', text: n.id }),
        h('div', { class: 'd-type', text: n.type + (n.namespace ? ' · ' + n.namespace : '') })),
      h('button', { class: 'icon-btn d-close', 'aria-label': 'Close details', onclick: function () { selectNode(null, {}); } }, '✕'));
    body.appendChild(head);
    if (n.file_path) body.appendChild(h('p', { class: 'd-file', text: n.file_path }));
    if (n.summary && n.summary !== n.type) body.appendChild(h('p', { class: 'd-summary', text: n.summary }));

    var stats = h('div', { class: 'd-stats' },
      dStat('rank', '#' + (rankOf[idx] + 1) + ' of ' + N),
      dStat('out', String(n.out)), dStat('in', String(n.in)));
    if (n.facts && n.facts.loc) stats.appendChild(dStat('loc', String(n.facts.loc)));
    if (n.facts && n.facts.change_frequency) stats.appendChild(dStat('churn', n.facts.change_frequency));
    body.appendChild(stats);

    var actions = h('div', { class: 'd-actions' },
      h('button', { class: 'btn', onclick: function () { showInGraph(idx); } }, 'Show in graph'),
      h('button', { class: 'btn', onclick: function () { setFocus(idx); } }, 'Focus neighborhood'),
      h('button', { class: 'btn', onclick: function () { openPathBar(); $('path-from').value = n.id; $('path-to').focus(); } }, 'Path from here'),
      h('button', { class: 'btn', onclick: function () { copyMarkdown(idx, this); } }, 'Copy for AI'));
    body.appendChild(actions);

    var cycles = cycleMembership[idx];
    if (cycles) {
      body.appendChild(h('div', { class: 'd-warning', text: 'Part of ' + cycles.length + ' dependency cycle' + (cycles.length > 1 ? 's' : '') + ' — see Overview → Cycles.' }));
    }

    renderFacts(body, n);
    renderRelations(body, idx);
  }

  function dStat(label, value) {
    var el = h('span', { class: 'd-stat' });
    el.appendChild(h('b', { text: value }));
    el.appendChild(document.createTextNode(' ' + label));
    return el;
  }

  function factSection(title) { return h('div', { class: 'd-section' }, h('h4', { text: title })); }
  function addList(section, items, renderItem, capNote) {
    var ul = h('ul', { class: 'd-list' });
    items.forEach(function (item) { ul.appendChild(renderItem(item)); });
    section.appendChild(ul);
    if (capNote) section.appendChild(h('div', { class: 'd-more', text: capNote }));
    return section;
  }

  function renderFacts(body, n) {
    var f = n.facts || {};
    var kv = [];
    ['table_name', 'queue', 'verb', 'path', 'route_name', 'engine', 'service_type',
     'concern_type', 'concern_scope', 'controller', 'action'].forEach(function (key) {
      if (f[key] !== undefined && f[key] !== null && f[key] !== '') kv.push([key.replace(/_/g, ' '), String(f[key])]);
    });
    if (f.partial !== undefined) kv.push(['kind', f.partial ? 'partial' : 'template']);
    if (kv.length) {
      var sec = factSection('About');
      var dl = h('dl', { class: 'd-kv' });
      kv.forEach(function (pair) {
        dl.appendChild(h('div', {}, h('dt', { text: pair[0] }), h('dd', { text: pair[1] })));
      });
      sec.appendChild(dl);
      body.appendChild(sec);
    }

    if (f.columns && f.columns.length) {
      var csec = factSection('Columns (' + (f.columns_total || f.columns.length) + ')');
      var tbl = h('table', { class: 'd-cols' });
      f.columns.forEach(function (c) {
        tbl.appendChild(h('tr', {},
          h('td', { text: c.name || '' }),
          h('td', { class: 'c-type', text: (c.type || '') + (c.null === false ? ' · not null' : '') })));
      });
      csec.appendChild(tbl);
      if (f.columns_total > f.columns.length) csec.appendChild(h('div', { class: 'd-more', text: '+' + (f.columns_total - f.columns.length) + ' more (see the extraction index)' }));
      body.appendChild(csec);
    }

    if (f.associations && f.associations.length) {
      body.appendChild(addList(factSection('Associations'), f.associations, function (a) {
        var li = h('li', {});
        li.appendChild(h('span', { class: 'sub', text: (a.macro || '') + ' ' }));
        var target = a.target && idToIdx[a.target] !== undefined
          ? h('button', { class: 'unit-link', text: a.name || a.target, onclick: jumpTo(idToIdx[a.target]) })
          : h('span', { text: a.name || a.target || '' });
        li.appendChild(target);
        var extras = [];
        if (a.through) extras.push('through ' + a.through);
        if (a.polymorphic) extras.push('polymorphic');
        if (a.dependent) extras.push('dependent: ' + a.dependent);
        if (a.optional) extras.push('optional');
        if (extras.length) li.appendChild(h('span', { class: 'via-tag', text: extras.join(' · ') }));
        return li;
      }));
    }

    if (f.callbacks && f.callbacks.length) {
      body.appendChild(addList(factSection('Callbacks'), f.callbacks, function (cb) {
        var li = h('li', {}, h('span', { text: (cb.type || '') + ' ' }), h('strong', { text: String(cb.filter || '') }));
        if (cb.side_effects) {
          Object.keys(cb.side_effects).forEach(function (kind) {
            li.appendChild(h('div', { class: 'side-effects', text: kind.replace(/_/g, ' ') + ': ' + cb.side_effects[kind].join(', ') }));
          });
        }
        return li;
      }));
    }

    if (f.validations && f.validations.length) {
      body.appendChild(addList(factSection('Validations'), f.validations, function (v) {
        return h('li', { text: String(v) });
      }));
    }

    simpleListSection(body, 'Scopes', f.scopes);
    if (f.enums && Object.keys(f.enums).length) {
      var esec = factSection('Enums');
      var edl = h('dl', { class: 'd-kv' });
      Object.keys(f.enums).forEach(function (col) {
        edl.appendChild(h('div', {}, h('dt', { text: col }),
          h('dd', { text: Array.isArray(f.enums[col]) ? f.enums[col].join(', ') : String(f.enums[col]) })));
      });
      esec.appendChild(edl);
      body.appendChild(esec);
    }
    if (f.sti) {
      body.appendChild(h('div', { class: 'd-section' }, h('h4', { text: 'STI' }),
        h('div', { class: 'd-kv', text: f.sti.child ? 'Inherits from ' + (f.sti.parent || 'base') : 'STI base class' })));
    }
    simpleListSection(body, 'Concerns', f.concerns);

    if (f.actions && f.actions.length) {
      var routes = f.routes || {};
      body.appendChild(addList(factSection('Actions'), f.actions, function (a) {
        var li = h('li', {}, h('strong', { text: '#' + a }));
        (routes[a] || []).forEach(function (r) { li.appendChild(h('span', { class: 'via-tag', text: r })); });
        return li;
      }));
    }
    simpleListSection(body, 'Filters', f.filters);
    if (f.permitted_params && Object.keys(f.permitted_params).length) {
      var psec = factSection('Permitted params');
      var pdl = h('dl', { class: 'd-kv' });
      Object.keys(f.permitted_params).forEach(function (m) {
        pdl.appendChild(h('div', {}, h('dt', { text: m }), h('dd', { text: f.permitted_params[m].join(', ') })));
      });
      psec.appendChild(pdl);
      body.appendChild(psec);
    }

    simpleListSection(body, 'Renders', f.renders);
    simpleListSection(body, 'Helpers used', f.helpers);
    simpleListSection(body, 'Entry points', f.entry_points);
    simpleListSection(body, 'Public methods', f.public_methods);
    simpleListSection(body, 'Enqueues', f.enqueues);
    simpleListSection(body, 'Retries on', f.retry_on);
    simpleListSection(body, 'Callbacks defined', f.callbacks_defined);
    simpleListSection(body, 'Scopes defined', f.scopes_defined);
    if (f.templates && Object.keys(f.templates).length) {
      var tsec = factSection('Templates');
      var tdl = h('dl', { class: 'd-kv' });
      Object.keys(f.templates).forEach(function (a) {
        tdl.appendChild(h('div', {}, h('dt', { text: a }),
          h('dd', { text: Array.isArray(f.templates[a]) ? f.templates[a].join(', ') : String(f.templates[a]) })));
      });
      tsec.appendChild(tdl);
      body.appendChild(tsec);
    }
  }

  function simpleListSection(body, title, items) {
    if (!items || !items.length) return;
    body.appendChild(addList(factSection(title), items, function (item) {
      return h('li', { text: typeof item === 'string' ? item : JSON.stringify(item) });
    }));
  }

  function renderRelations(body, idx) {
    [['Depends on', outAdj[idx]], ['Depended on by', inAdj[idx]]].forEach(function (pair) {
      var adj = pair[1];
      if (!adj.length) return;
      var byVia = {};
      adj.forEach(function (a) { var v = a.via || 'unlabeled'; (byVia[v] = byVia[v] || []).push(a.t); });
      var sec = factSection(pair[0] + ' (' + adj.length + ')');
      Object.keys(byVia).sort().forEach(function (via) {
        var ul = h('ul', { class: 'd-list' });
        var targets = byVia[via].slice().sort(function (a, b) { return NODES[a].id < NODES[b].id ? -1 : 1; });
        targets.slice(0, 30).forEach(function (t) {
          ul.appendChild(h('li', {},
            h('button', { class: 'unit-link', text: NODES[t].id, onclick: jumpTo(t) }),
            h('span', { class: 'via-tag', text: via })));
        });
        sec.appendChild(ul);
        if (targets.length > 30) sec.appendChild(h('div', { class: 'd-more', text: '+' + (targets.length - 30) + ' more' }));
      });
      body.appendChild(sec);
    });
    $('detail').hidden = false;
  }

  // Select + inspect a unit WITHOUT yanking the user out of their current
  // view — the detail panel opens beside table/overview just as well. Only
  // the ERD needs a switch when the target isn't a model. The detail panel's
  // "Show in graph" action does the explicit jump.
  function jumpTo(idx) {
    return function () {
      if (state.view === 'erd' && NODES[idx].type !== 'model') switchView('graph', {});
      var canvasMode = state.view === 'graph' || state.view === 'erd';
      if (canvasMode && state.focus && scene && !scene.nodeSet[idx]) clearFocus();
      selectNode(idx, { openDetail: true, center: canvasMode });
    };
  }

  function showInGraph(idx) {
    if (state.view !== 'graph') switchView('graph', {});
    if (scene && !scene.nodeSet[idx]) {
      if (state.focus) clearFocus();
      if (scene && !scene.nodeSet[idx] && state.capTop) { setFocus(idx); }
    }
    selectNode(idx, { openDetail: true, center: true });
  }

  /* ================= copy for AI ================= */

  function markdownFor(idx) {
    var n = NODES[idx];
    var lines = ['# ' + n.id + ' (' + n.type + ')'];
    if (n.file_path) lines.push('File: ' + n.file_path);
    lines.push('PageRank: ' + (n.pagerank || 0) + ' (rank #' + (rankOf[idx] + 1) + ' of ' + N + ') · out ' + n.out + ' · in ' + n.in);
    if (n.summary && n.summary !== n.type) lines.push('Summary: ' + n.summary);
    var f = n.facts || {};
    var factLines = [];
    Object.keys(f).forEach(function (key) {
      var v = f[key];
      if (v === null || v === undefined) return;
      if (Array.isArray(v)) {
        if (!v.length) return;
        factLines.push('- ' + key + ': ' + v.map(function (item) {
          return typeof item === 'string' ? item : JSON.stringify(item);
        }).join('; '));
      } else if (typeof v === 'object') {
        if (!Object.keys(v).length) return;
        factLines.push('- ' + key + ': ' + JSON.stringify(v));
      } else {
        factLines.push('- ' + key + ': ' + v);
      }
    });
    if (factLines.length) lines.push('', '## Facts', factLines.join('\n'));
    if (outAdj[idx].length) {
      lines.push('', '## Depends on');
      outAdj[idx].forEach(function (a) { lines.push('- ' + NODES[a.t].id + ' (' + (a.via || 'unlabeled') + ')'); });
    }
    if (inAdj[idx].length) {
      lines.push('', '## Depended on by');
      inAdj[idx].forEach(function (a) { lines.push('- ' + NODES[a.t].id + ' (' + (a.via || 'unlabeled') + ')'); });
    }
    return lines.join('\n') + '\n';
  }

  function copyMarkdown(idx, btn) {
    var text = markdownFor(idx);
    var done = function () {
      var old = btn.textContent;
      btn.textContent = 'Copied ✓';
      setTimeout(function () { btn.textContent = old; }, 1400);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
    } else { fallbackCopy(text); done(); }
  }
  function fallbackCopy(text) {
    var ta = h('textarea', { style: { position: 'fixed', opacity: '0' } });
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (e) { /* best effort */ }
    document.body.removeChild(ta);
  }

  /* ================= search ================= */

  var searchInput = $('search'), searchResults = $('search-results');
  var searchSel = -1, searchHits = [];

  function scoreMatch(node, q, wordRe) {
    var id = node.id.toLowerCase(), label = node.label.toLowerCase();
    var file = (node.file_path || '').toLowerCase();
    if (id === q || label === q) return 100;
    if (label.indexOf(q) === 0 || id.indexOf(q) === 0) return 80;
    if (wordRe.test(id)) return 60;
    if (id.indexOf(q) >= 0) return 40;
    if (file.indexOf(q) >= 0) return 20;
    return 0;
  }

  function runSearch() {
    var q = searchInput.value.trim().toLowerCase();
    clear(searchResults);
    searchSel = -1; searchHits = [];
    if (!q) { searchResults.hidden = true; searchInput.setAttribute('aria-expanded', 'false'); return; }
    var hits = [];
    var wordRe = new RegExp('(^|[^a-z0-9])' + q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
    for (var idx = 0; idx < N; idx++) {
      var s = scoreMatch(NODES[idx], q, wordRe);
      if (s > 0) hits.push([s + percentile(idx) * 5, idx]);
    }
    hits.sort(function (a, b) { return b[0] - a[0]; });
    searchHits = hits.slice(0, 12).map(function (hitPair) { return hitPair[1]; });
    if (!searchHits.length) {
      searchResults.appendChild(h('li', { class: 'no-hits', text: 'No units match “' + searchInput.value.trim() + '”' }));
    }
    searchHits.forEach(function (idx, i) {
      var n = NODES[idx];
      var li = h('li', { role: 'option', id: 'hit-' + i, 'aria-selected': 'false' },
        h('span', { class: 'legend-swatch', style: { background: colorOf(n), color: glyphInk(colorOf(n)) }, text: glyphFor(n) }),
        h('span', { class: 'hit-label', text: n.id }),
        h('span', { class: 'hit-sub', text: n.type + (n.file_path ? ' · ' + n.file_path : '') }));
      li.addEventListener('click', function () { pickSearch(idx); });
      searchResults.appendChild(li);
    });
    searchResults.hidden = false;
    searchInput.setAttribute('aria-expanded', 'true');
  }

  function pickSearch(idx) {
    searchResults.hidden = true;
    searchInput.setAttribute('aria-expanded', 'false');
    searchInput.value = '';
    jumpTo(idx)();
  }

  searchInput.addEventListener('input', runSearch);
  searchInput.addEventListener('keydown', function (ev) {
    if (searchResults.hidden) return;
    if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
      ev.preventDefault();
      var dir = ev.key === 'ArrowDown' ? 1 : -1;
      if (searchSel === -1 && dir === -1) searchSel = searchHits.length - 1;
      else searchSel = (searchSel + dir + searchHits.length) % Math.max(searchHits.length, 1);
      Array.prototype.forEach.call(searchResults.children, function (li, i) {
        li.setAttribute('aria-selected', i === searchSel ? 'true' : 'false');
      });
      var active = searchResults.children[searchSel];
      if (active) { active.scrollIntoView({ block: 'nearest' }); searchInput.setAttribute('aria-activedescendant', active.id); }
    } else if (ev.key === 'Enter') {
      if (searchHits.length) pickSearch(searchHits[Math.max(searchSel, 0)]);
    } else if (ev.key === 'Escape') {
      searchResults.hidden = true;
      searchInput.setAttribute('aria-expanded', 'false');
      searchInput.blur();
    }
  });
  document.addEventListener('click', function (ev) {
    if (!searchResults.hidden && !searchResults.contains(ev.target) && ev.target !== searchInput) {
      searchResults.hidden = true;
      searchInput.setAttribute('aria-expanded', 'false');
    }
  });

  /* ================= path finder ================= */

  function openPathBar() {
    $('path-bar').hidden = false;
    $('path-result').textContent = '';
    $('path-from').focus();
  }
  function closePathBar() {
    $('path-bar').hidden = true;
    clearPath();
  }
  function clearPath() {
    if (state.path) { state.path = null; rebuildScene(); }
    $('path-result').textContent = '';
  }
  $('path-mode-btn').addEventListener('click', openPathBar);
  $('path-close').addEventListener('click', closePathBar);

  function resolveUnit(text) {
    var q = text.trim();
    if (!q) return null;
    if (idToIdx[q] !== undefined) return idToIdx[q];
    var lower = q.toLowerCase();
    var exact = null, subs = [];
    for (var idx = 0; idx < N; idx++) {
      var id = NODES[idx].id.toLowerCase();
      if (id === lower) { exact = idx; break; }
      if (id.indexOf(lower) >= 0) subs.push(idx);
    }
    if (exact !== null) return exact;
    return subs.length >= 1 ? subs.sort(function (a, b) { return rankOf[a] - rankOf[b]; })[0] : null;
  }

  function findPath(from, to) {
    // BFS treating edges as undirected, ignoring display filters (a path is a
    // question about the app, not about what's currently drawn)
    var prev = {}; prev[from] = { n: -1, e: -1 };
    var queue = [from];
    while (queue.length) {
      var cur = queue.shift();
      if (cur === to) break;
      var expand = function (adj) {
        adj[cur].forEach(function (a) {
          if (a.t in prev) return;
          prev[a.t] = { n: cur, e: a.e };
          queue.push(a.t);
        });
      };
      expand(outAdj); expand(inAdj);
    }
    if (!(to in prev)) return null;
    var nodes = [], edges = [], cur2 = to;
    while (cur2 !== -1) {
      nodes.unshift(cur2);
      if (prev[cur2].e !== -1) edges.unshift(prev[cur2].e);
      cur2 = prev[cur2].n;
    }
    return { nodes: nodes, edges: edges };
  }

  $('path-go').addEventListener('click', tracePath);
  ['path-from', 'path-to'].forEach(function (id) {
    $(id).addEventListener('keydown', function (ev) { if (ev.key === 'Enter') tracePath(); });
  });

  function tracePath() {
    var from = resolveUnit($('path-from').value);
    var to = resolveUnit($('path-to').value);
    var out = $('path-result');
    if (from === null || to === null) {
      out.textContent = from === null ? 'No unit matches the start.' : 'No unit matches the destination.';
      return;
    }
    if (from === to) { out.textContent = 'Start and destination are the same unit.'; return; }
    var result = findPath(from, to);
    if (!result) {
      out.textContent = 'No connection between ' + NODES[from].id + ' and ' + NODES[to].id + '.';
      announce(out.textContent);
      return;
    }
    state.focus = null;
    $('focus-section').hidden = true;
    state.path = result;
    if (state.view !== 'graph') switchView('graph', { keepPath: true });
    else rebuildScene();
    var hops = result.nodes.length - 1;
    out.textContent = hops + ' hop' + (hops === 1 ? '' : 's') + ': ' +
      result.nodes.map(function (idx) { return NODES[idx].label; }).join(' → ');
    announce('Path found with ' + hops + ' hops');
    syncHash();
  }

  /* ================= sidebar: legend + via filters ================= */

  // Shared builder for the two filter sections. Each row: click toggles,
  // the hover "only" button solos (isolates) that entry, and the header's
  // "show all" resets. Everything persists across reloads.
  function buildFilterRows(opts) {
    var wrap = $(opts.wrapId);
    clear(wrap);
    var anyOff = opts.keys.some(function (k) { return opts.offMap[k]; });
    var reset = $(opts.resetId);
    reset.hidden = !anyOff;
    reset.onclick = function () {
      opts.keys.forEach(function (k) { delete opts.offMap[k]; });
      persistUi(); buildAllFilters(); rebuildScene();
    };
    opts.keys.forEach(function (key) {
      var row = h('div', { class: opts.rowClass, role: 'group' });
      var toggle = h('button', {
        class: 'row-toggle', 'aria-pressed': String(!opts.offMap[key]),
        onclick: function () {
          if (opts.offMap[key]) delete opts.offMap[key]; else opts.offMap[key] = true;
          persistUi(); buildAllFilters(); rebuildScene();
        }
      }, opts.renderLabel(key));
      var solo = h('button', {
        class: 'solo-btn', 'aria-label': 'Show only ' + opts.labelFor(key),
        onclick: function () {
          opts.keys.forEach(function (k) { if (k !== key) opts.offMap[k] = true; else delete opts.offMap[k]; });
          persistUi(); buildAllFilters(); rebuildScene();
        }
      }, 'only');
      row.appendChild(toggle);
      row.appendChild(solo);
      wrap.appendChild(row);
    });
  }

  function buildLegend() {
    var counts = {};
    NODES.forEach(function (n) { counts[n.group] = (counts[n.group] || 0) + 1; });
    var keys = GROUPS.map(function (g) { return g.key; }).filter(function (k) { return counts[k]; });
    var byKey = {};
    GROUPS.forEach(function (g) { byKey[g.key] = g; });
    buildFilterRows({
      wrapId: 'legend', resetId: 'legend-reset', rowClass: 'legend-row',
      keys: keys, offMap: state.groupsOff,
      labelFor: function (k) { return byKey[k].label; },
      renderLabel: function (k) {
        var color = pal()[k] || pal().other;
        return [
          h('span', { class: 'legend-swatch', style: { background: color, color: glyphInk(color) }, text: byKey[k].glyph }),
          h('span', { text: byKey[k].label }),
          h('span', { class: 'legend-count', text: String(counts[k]) })
        ];
      }
    });
  }

  function buildViaFilter() {
    var vias = Object.keys(DATA.via_counts || {});
    buildFilterRows({
      wrapId: 'via-filter', resetId: 'via-reset', rowClass: 'via-row',
      keys: vias, offMap: state.viasOff,
      labelFor: function (v) { return v === '' ? 'unlabeled' : v; },
      renderLabel: function (v) {
        return [
          h('span', { class: 'via-key', 'aria-hidden': 'true' }),
          h('span', { text: v === '' ? 'unlabeled' : v }),
          h('span', { class: 'legend-count', text: String(DATA.via_counts[v]) })
        ];
      }
    });
  }

  function buildAllFilters() { buildLegend(); buildViaFilter(); }

  $('opt-labels').addEventListener('change', function () { state.showLabels = this.checked; persistUi(); draw(); });
  $('opt-orphans').addEventListener('change', function () { state.showOrphans = this.checked; persistUi(); rebuildScene(); });
  $('opt-cap').addEventListener('change', function () { state.capTop = this.checked; persistUi(); rebuildScene(); });

  /* ================= overview ================= */

  function renderOverview() {
    var root = $('overview');
    clear(root);
    var app = DATA.app || {};
    root.appendChild(h('h1', { class: 'ov-head', text: 'Codebase overview' }));
    var provBits = [];
    if (app.git_branch) provBits.push(app.git_branch + (app.git_sha && app.git_sha !== 'unknown' ? '@' + String(app.git_sha).slice(0, 8) : ''));
    if (app.rails_version) provBits.push('Rails ' + app.rails_version);
    if (app.ruby_version) provBits.push('Ruby ' + app.ruby_version);
    if (app.extracted_at) provBits.push('extracted ' + app.extracted_at.replace('T', ' ').slice(0, 16));
    root.appendChild(h('p', { class: 'ov-sub', text: provBits.join(' · ') || 'Extraction provenance unavailable' }));

    var types = DATA.types || {};
    var cycles = (ANALYSIS.cycles || []).length;
    var orphans = (ANALYSIS.orphans || []).length;
    var tiles = h('div', { class: 'tile-row' },
      tile('Units', String(N), null),
      tile('Relationships', String(EDGES.length), null),
      tile('Models', String(types.model || 0), null),
      tile('Controllers', String(types.controller || 0), null),
      statusTile('Cycles', cycles, cycles === 0 ? 'good' : cycles > 3 ? 'serious' : 'warning',
        cycles === 0 ? 'none detected' : 'circular dependencies'),
      statusTile('Orphans', orphans, orphans === 0 ? 'good' : 'warning',
        orphans === 0 ? 'everything referenced' : 'nothing depends on these'));
    root.appendChild(tiles);

    var grid = h('div', { class: 'ov-grid' });
    root.appendChild(grid);
    grid.appendChild(typeChartCard(types));
    grid.appendChild(topRankCard());
    grid.appendChild(hubsCard());
    grid.appendChild(cyclesCard());
    grid.appendChild(healthCard());
    grid.appendChild(viaCard());
  }

  function tile(label, value, note) {
    return h('div', { class: 'tile' },
      h('div', { class: 'tile-label', text: label }),
      h('div', { class: 'tile-value', text: value }),
      note ? h('div', { class: 'tile-note', text: note }) : null);
  }
  function statusTile(label, count, status, note) {
    var icons = { good: '✓', warning: '▲', serious: '◆', critical: '✕' };
    var t = h('div', { class: 'tile tile-alert' },
      h('div', { class: 'tile-label', text: label }),
      h('div', { class: 'tile-value' },
        h('span', { class: 'status-ico status-' + status, 'aria-hidden': 'true', text: icons[status] }),
        h('span', { text: String(count) })),
      h('div', { class: 'tile-note', text: note }));
    return t;
  }

  function typeChartCard(types) {
    var card = h('div', { class: 'card' },
      h('h3', { text: 'Units by type' }),
      h('p', { class: 'card-sub', text: 'Click a row to open that type in the table view' }));
    var entries = Object.keys(types).map(function (t) { return [t, types[t]]; });
    entries.sort(function (a, b) { return b[1] - a[1]; });
    var top = entries.slice(0, 12);
    var rest = entries.slice(12).reduce(function (sum, e) { return sum + e[1]; }, 0);
    var max = top.length ? top[0][1] : 1;
    var bars = h('div', { class: 'bars', role: 'list' });
    top.forEach(function (e) {
      var row = h('span', {
        class: 'bar-row-btn', role: 'listitem', tabindex: '0',
        onclick: function () { state.tableFilter.type = e[0]; switchView('table', {}); },
        onkeydown: function (ev) { if (ev.key === 'Enter') { state.tableFilter.type = e[0]; switchView('table', {}); } }
      },
        h('span', { class: 'bar-label', text: e[0] }),
        h('span', { class: 'bar-track' }, h('span', { class: 'bar-fill', style: { width: (e[1] / max * 100) + '%' } })),
        h('span', { class: 'bar-value', text: String(e[1]) }));
      bars.appendChild(row);
    });
    if (rest > 0) {
      bars.appendChild(h('span', { class: 'bar-row-btn' },
        h('span', { class: 'bar-label', text: 'other' }),
        h('span', { class: 'bar-track' }, h('span', { class: 'bar-fill', style: { width: (rest / max * 100) + '%', opacity: 0.45 } })),
        h('span', { class: 'bar-value', text: String(rest) })));
    }
    card.appendChild(bars);
    return card;
  }

  function unitPill(idx, extra) {
    var n = NODES[idx];
    return h('li', {},
      h('button', { class: 'unit-link', text: n.id, onclick: jumpTo(idx) }),
      h('span', { class: 'pill' },
        h('span', { class: 'pill-dot', style: { background: colorOf(n) } }),
        h('span', { text: n.type })),
      extra ? h('span', { class: 'h-count', text: extra }) : null);
  }

  function topRankCard() {
    var card = h('div', { class: 'card' },
      h('h3', { text: 'Most important units' }),
      h('p', { class: 'card-sub', text: 'PageRank over the dependency graph — where reading pays off first' }));
    var ul = h('ul', { class: 'health-list' });
    rankOrder.slice(0, 10).forEach(function (idx) {
      ul.appendChild(unitPill(idx, '← ' + NODES[idx].in));
    });
    card.appendChild(ul);
    return card;
  }

  function hubsCard() {
    var card = h('div', { class: 'card' },
      h('h3', { text: 'Hubs' }),
      h('p', { class: 'card-sub', text: 'Heavily depended-on units — changes here ripple widest' }));
    var hubs = ANALYSIS.hubs || [];
    if (!hubs.length) { card.appendChild(h('p', { class: 'card-sub', text: 'No hub data in this extraction.' })); return card; }
    var ul = h('ul', { class: 'health-list' });
    hubs.slice(0, 10).forEach(function (hub) {
      ul.appendChild(unitPill(hub.node, (hub.dependent_count || NODES[hub.node].in) + ' dependents'));
    });
    card.appendChild(ul);
    return card;
  }

  function cyclesCard() {
    var card = h('div', { class: 'card' },
      h('h3', { text: 'Dependency cycles' }),
      h('p', { class: 'card-sub', text: 'Mutual dependencies — expected for paired associations, worth review elsewhere' }));
    var cycles = ANALYSIS.cycles || [];
    if (!cycles.length) { card.appendChild(h('p', { class: 'card-sub', text: 'None detected. 🎉' })); return card; }
    var ul = h('ul', { class: 'health-list' });
    cycles.slice(0, 8).forEach(function (cycle) {
      var li = h('li', {});
      var chain = h('span', { class: 'cycle-chain' });
      cycle.forEach(function (idx, i) {
        if (i) chain.appendChild(document.createTextNode(' → '));
        chain.appendChild(h('button', { class: 'unit-link', text: NODES[idx].label, onclick: jumpTo(idx) }));
      });
      li.appendChild(chain);
      ul.appendChild(li);
    });
    if (cycles.length > 8) ul.appendChild(h('li', {}, h('span', { class: 'h-count', text: '+' + (cycles.length - 8) + ' more cycles' })));
    card.appendChild(ul);
    return card;
  }

  function healthCard() {
    var card = h('div', { class: 'card' },
      h('h3', { text: 'Loose ends' }),
      h('p', { class: 'card-sub', text: 'Orphans (nothing depends on them) and bridges (fragile connectors)' }));
    var ul = h('ul', { class: 'health-list' });
    (ANALYSIS.orphans || []).slice(0, 8).forEach(function (idx) { ul.appendChild(unitPill(idx, 'orphan')); });
    (ANALYSIS.bridges || []).slice(0, 6).forEach(function (b) { ul.appendChild(unitPill(b.node, 'bridge · score ' + (b.score || '—'))); });
    if (!ul.children.length) ul.appendChild(h('li', {}, h('span', { class: 'h-count', text: 'Nothing flagged.' })));
    card.appendChild(ul);
    return card;
  }

  function viaCard() {
    var card = h('div', { class: 'card' },
      h('h3', { text: 'Relationship kinds' }),
      h('p', { class: 'card-sub', text: 'How units point at each other across the graph' }));
    var vias = DATA.via_counts || {};
    var keys = Object.keys(vias);
    var max = keys.length ? vias[keys[0]] : 1;
    var bars = h('div', { class: 'bars' });
    keys.slice(0, 12).forEach(function (via) {
      bars.appendChild(h('span', { class: 'bar-row-btn' },
        h('span', { class: 'bar-label', text: via || 'unlabeled' }),
        h('span', { class: 'bar-track' }, h('span', { class: 'bar-fill', style: { width: (vias[via] / max * 100) + '%' } })),
        h('span', { class: 'bar-value', text: String(vias[via]) })));
    });
    card.appendChild(bars);
    return card;
  }

  /* ================= table view ================= */

  function renderTable() {
    var root = $('table-view');
    clear(root);
    var tools = h('div', { class: 'table-tools' });
    var q = h('input', {
      type: 'search', placeholder: 'Filter rows…', 'aria-label': 'Filter table rows', value: state.tableFilter.q,
      oninput: function () { state.tableFilter.q = this.value; renderTableBody(); }
    });
    q.style.cssText = 'padding:6px 10px;border:1px solid var(--baseline);border-radius:7px;background:var(--page);color:var(--ink);font:inherit;';
    var sel = h('select', { 'aria-label': 'Filter by type', onchange: function () { state.tableFilter.type = this.value; renderTableBody(); } });
    sel.style.cssText = q.style.cssText;
    sel.appendChild(h('option', { value: '', text: 'All types' }));
    Object.keys(DATA.types || {}).forEach(function (t) {
      sel.appendChild(h('option', { value: t, text: t + ' (' + DATA.types[t] + ')', selected: state.tableFilter.type === t }));
    });
    tools.appendChild(q); tools.appendChild(sel);
    tools.appendChild(h('span', { class: 'hint', id: 'table-count' }));
    root.appendChild(tools);

    var cols = [
      { key: 'id', label: 'Unit' }, { key: 'type', label: 'Type' },
      { key: 'file', label: 'File' }, { key: 'score', label: 'PageRank', num: true },
      { key: 'in', label: 'In', num: true }, { key: 'out', label: 'Out', num: true },
      { key: 'summary', label: 'Summary' }
    ];
    var thead = h('thead', {}, h('tr', {}, cols.map(function (c) {
      return h('th', {
        scope: 'col', 'data-key': c.key,
        onclick: function () {
          state.tableSort = { key: c.key, dir: state.tableSort.key === c.key ? -state.tableSort.dir : (c.num ? -1 : 1) };
          renderTableBody();
        }
      }, c.label);
    })));
    var table = h('table', { class: 'units' }, thead, h('tbody', {}));
    root.appendChild(table);
    renderTableBody();

    function renderTableBody() {
      var tbody = table.querySelector('tbody');
      clear(tbody);
      var qv = state.tableFilter.q.trim().toLowerCase();
      var rows = [];
      for (var idx = 0; idx < N; idx++) {
        var n = NODES[idx];
        if (state.tableFilter.type && n.type !== state.tableFilter.type) continue;
        if (qv && haystack[idx].indexOf(qv) < 0) continue;
        rows.push(idx);
      }
      var key = state.tableSort.key, dir = state.tableSort.dir;
      rows.sort(function (a, b) {
        var va = tableValue(a, key), vb = tableValue(b, key);
        if (va < vb) return -dir;
        if (va > vb) return dir;
        return 0;
      });
      table.querySelectorAll('th').forEach(function (th) {
        th.setAttribute('aria-sort', th.getAttribute('data-key') === key ? (dir > 0 ? 'ascending' : 'descending') : 'none');
      });
      var cap = 1500;
      rows.slice(0, cap).forEach(function (idx) {
        var n = NODES[idx];
        var tr = h('tr', { tabindex: '0', onclick: jumpTo(idx), onkeydown: function (ev) { if (ev.key === 'Enter') jumpTo(idx)(); } },
          h('td', {},
            h('span', { class: 'legend-swatch row-glyph', style: { background: colorOf(n), color: glyphInk(colorOf(n)), display: 'inline-flex' }, text: glyphFor(n) }),
            document.createTextNode(n.id)),
          h('td', { text: n.type }),
          h('td', { class: 't-file', text: n.file_path || '' }),
          h('td', { class: 'num', text: n.pagerank ? n.pagerank.toFixed(4) : '—' }),
          h('td', { class: 'num', text: String(n.in) }),
          h('td', { class: 'num', text: String(n.out) }),
          h('td', { class: 't-file', text: n.summary !== n.type ? n.summary : '' }));
        tbody.appendChild(tr);
      });
      $('table-count').textContent = rows.length + ' unit' + (rows.length === 1 ? '' : 's') +
        (rows.length > cap ? ' (showing first ' + cap + ')' : '');
    }
  }

  function tableValue(idx, key) {
    var n = NODES[idx];
    switch (key) {
      case 'score': return scores[idx];
      case 'in': return n.in;
      case 'out': return n.out;
      case 'file': return n.file_path || '';
      case 'summary': return n.summary || '';
      case 'type': return n.type;
      default: return n.id.toLowerCase();
    }
  }

  /* ================= views + routing ================= */

  function switchView(name, opts) {
    state.view = name;
    document.querySelectorAll('.tab').forEach(function (tab) {
      tab.setAttribute('aria-current', tab.getAttribute('data-view') === name ? 'true' : 'false');
    });
    var canvasMode = name === 'graph' || name === 'erd';
    $('canvas-wrap').style.display = canvasMode ? '' : 'none';
    $('overview').hidden = name !== 'overview';
    $('table-view').hidden = name !== 'table';
    $('sidebar').style.display = canvasMode ? '' : 'none';
    if (!opts.keepPath && state.path) { state.path = null; $('path-bar').hidden = true; }
    if (name === 'overview') renderOverview();
    if (name === 'table') renderTable();
    if (canvasMode) { resize(); rebuildScene(); }
    syncHash();
    updateStatus();
  }

  document.querySelectorAll('.tab').forEach(function (tab) {
    tab.addEventListener('click', function () { switchView(tab.getAttribute('data-view'), {}); });
  });

  var suppressHash = false;
  function syncHash() {
    var hash = '#/' + state.view;
    if (state.selected !== null) hash = '#/unit/' + encodeURIComponent(NODES[state.selected].id) + '/' + state.view;
    if (state.path && state.path.nodes) {
      hash = '#/path/' + encodeURIComponent(NODES[state.path.nodes[0]].id) + '/' +
        encodeURIComponent(NODES[state.path.nodes[state.path.nodes.length - 1]].id);
    }
    if (location.hash !== hash) {
      suppressHash = true;
      try { history.replaceState(null, '', hash); } catch (e) { location.hash = hash; }
      setTimeout(function () { suppressHash = false; }, 0);
    }
  }

  function applyHash() {
    if (suppressHash) return;
    var parts = location.hash.replace(/^#\/?/, '').split('/').map(function (p) {
      try { return decodeURIComponent(p); } catch (e) { return p; } // tolerate truncated escapes
    }).filter(Boolean);
    if (!parts.length) { switchView('graph', {}); return; }
    if (parts[0] === 'unit' && parts[1] && idToIdx[parts[1]] !== undefined) {
      var viewName = parts[2] && ['graph', 'erd', 'table', 'overview'].indexOf(parts[2]) >= 0 ? parts[2] : 'graph';
      switchView(viewName, {});
      selectNode(idToIdx[parts[1]], { openDetail: true, center: true });
      return;
    }
    if (parts[0] === 'path' && parts[1] && parts[2]) {
      switchView('graph', { keepPath: true });
      openPathBar();
      $('path-from').value = parts[1];
      $('path-to').value = parts[2];
      tracePath();
      return;
    }
    if (['graph', 'erd', 'table', 'overview'].indexOf(parts[0]) >= 0) switchView(parts[0], {});
    else switchView('graph', {});
  }
  window.addEventListener('hashchange', applyHash);

  function updateStatus() {
    var msg = N + ' units · ' + EDGES.length + ' relationships';
    if (scene && isCanvasView() && (scene.nodes.length !== N || scene.edges.length !== EDGES.length)) {
      msg += ' — showing ' + scene.nodes.length + ' units, ' + scene.edges.length + ' links';
      if (state.capTop && N > LARGE_N && state.view === 'graph' && !state.focus && !state.path) {
        msg += ' (top ' + CAP_K + ' by PageRank — see Display)';
      }
    }
    $('status-counts').textContent = msg;
  }

  /* ================= global keys, theme, help ================= */

  document.addEventListener('keydown', function (ev) {
    if (ev.ctrlKey || ev.metaKey || ev.altKey) return; // browser/OS chords stay theirs
    var tag = (ev.target.tagName || '').toLowerCase();
    if (tag === 'input' || tag === 'textarea' || tag === 'select') return;
    if (ev.key === '/') { ev.preventDefault(); searchInput.focus(); searchInput.select(); }
    else if (ev.key === '?') { $('help').showModal(); }
    else if (ev.key === 'p') { openPathBar(); }
    else if (ev.key >= '1' && ev.key <= '4') {
      switchView(['overview', 'graph', 'erd', 'table'][+ev.key - 1], {});
    } else if (ev.key === 'Escape' && !$('help').open) {
      if (state.path) closePathBar();
      else if (state.focus) clearFocus();
      else if (state.selected !== null) selectNode(null, {});
    }
  });

  $('help-btn').addEventListener('click', function () { $('help').showModal(); });
  $('theme-toggle').addEventListener('click', function () {
    var next = theme() === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    try { localStorage.setItem('woods-explorer-theme', next); } catch (e) { /* sandboxed */ }
    chromeCache = null;
    buildLegend();
    if (state.view === 'overview') renderOverview();
    if (state.view === 'table') renderTable();
    if (state.selected !== null && !$('detail').hidden) openDetail(state.selected);
    draw();
  });

  /* ================= boot ================= */

  var app = DATA.app || {};
  var metaBits = [];
  if (app.git_branch) metaBits.push(app.git_branch + (app.git_sha && app.git_sha !== 'unknown' ? '@' + String(app.git_sha).slice(0, 8) : ''));
  if (app.rails_version) metaBits.push('Rails ' + app.rails_version);
  $('app-meta').textContent = metaBits.join(' · ');
  document.title = 'Woods Explorer' + (app.git_branch ? ' — ' + app.git_branch : '');

  $('opt-labels').checked = state.showLabels;
  $('opt-orphans').checked = state.showOrphans;
  if (N > LARGE_N) {
    $('opt-cap-row').hidden = false;
    $('opt-cap').checked = state.capTop;
    $('opt-cap-text').textContent = 'Top ' + CAP_K + ' by PageRank only';
  }
  buildAllFilters();
  window.addEventListener('resize', resize);
  // The canvas buffer must track its container: the path bar, sidebar and
  // detail panel all change the stage size without a window resize.
  if (window.ResizeObserver) {
    new ResizeObserver(function () { resize(); }).observe(canvas.parentElement);
  }
  resize();
  if (location.hash && location.hash !== '#/') applyHash();
  else switchView(N > 0 ? 'graph' : 'overview', {});
  if (N === 0) {
    $('empty-note').hidden = false;
    $('empty-note').textContent = 'This extraction contains no units.';
  }

  // Expose the payload for AI agents and console spelunking.
  window.WOODS_EXPLORER = { data: DATA, markdownFor: markdownFor, version: DATA.schema };
})();
