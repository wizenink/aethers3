// aethers3 console — LiveView client + the ClusterField canvas hook.
// app.css is imported here so esbuild emits priv/static/assets/app.css alongside app.js.
import "../css/app.css"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

// ── ClusterField ────────────────────────────────────────────────────────────
// Renders ONLY real cluster state pushed from the server: topology from /cluster,
// particle flow from real per-node op-rate deltas. No simulation — an idle cluster
// is still, an unreachable one says so; nothing is invented.
const ClusterField = {
  mounted() {
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    const cvs = this.el, ctx = cvs.getContext("2d")
    const doc = document
    const css = getComputedStyle(document.documentElement)
    const V = n => css.getPropertyValue(n).trim()
    const C = {
      field0: () => V("--field-0"), teal: V("--teal"), gold: V("--gold"), down: V("--down"),
      ink: V("--ink"), muted: V("--muted"), faint: V("--faint"),
      write: V("--blue"), repair: V("--green"), ae: V("--violet"), shed: V("--amber"),
    }
    const OPS = {
      write: { color: C.write, min: 0.55 }, repair: { color: C.repair, min: 0.5 },
      ae: { color: C.ae, min: 0.45 }, shed: { color: C.shed, min: 0.42 },
    }
    const roNodes = doc.getElementById("ro-nodes"), roLeader = doc.getElementById("ro-leader")
    const roOps = doc.getElementById("ro-ops"), feedEl = doc.getElementById("feed")

    let W = 0, H = 0, cx = 0, cy = 0, R = 0, dpr = 1, N = 1
    let now = 0, offline = false, opsPerSec = 0
    const nodes = []

    const resize = () => {
      dpr = Math.min(window.devicePixelRatio || 1, 2)
      W = cvs.clientWidth; H = cvs.clientHeight
      if (!W || !H) return
      cvs.width = Math.round(W * dpr); cvs.height = Math.round(H * dpr)
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      cx = W / 2; cy = H / 2; R = Math.min(W, H) * 0.32; layout()
    }
    const layout = () => nodes.forEach(n => {
      n.ang = -Math.PI / 2 + (n.i / N) * 6.283; n.x = cx + Math.cos(n.ang) * R; n.y = cy + Math.sin(n.ang) * R
    })
    const upNodes = () => nodes.filter(n => n.up)
    const radiusOf = n => 12 + Math.sqrt(Math.max(n.count, 0)) * 0.34
    const short = id => String(id).replace(/^aether@/, "").replace(/\.aethr$/, "")

    // ── particles ──
    const parts = [], CAP = 460
    const spawn = (from, to, opKey) => {
      if (parts.length > CAP || !from || !to || from === to) return
      const op = OPS[opKey], mx = (from.x + to.x) / 2, my = (from.y + to.y) / 2
      parts.push({
        x0: from.x, y0: from.y, x1: to.x, y1: to.y, cxp: mx + (cx - mx) * 0.42, cyp: my + (cy - my) * 0.42,
        t: 0, sp: op.min + Math.random() * 0.35, color: op.color,
        size: 1.7 + Math.random() * 1.1, px: from.x, py: from.y,
      })
    }
    const spawnShed = node => {
      if (parts.length > CAP || !node) return
      const a = Math.random() * 6.28, d = 15 + Math.random() * 14
      parts.push({
        fade: true, x0: node.x, y0: node.y, x1: node.x + Math.cos(a) * d, y1: node.y + Math.sin(a) * d,
        t: 0, sp: 0.75 + Math.random() * 0.3, color: OPS.shed.color, size: 2 + Math.random(), px: node.x, py: node.y,
      })
    }
    const pointAt = (p, t) => {
      const u = 1 - t
      return [u * u * p.x0 + 2 * u * t * p.cxp + t * t * p.x1, u * u * p.y0 + 2 * u * t * p.cyp + t * t * p.y1]
    }

    // ── honest telemetry feed: real op counts + real node names, no invented keys.
    // Persisted to localStorage so a refresh restores the last couple of minutes of
    // real activity instead of starting blank; older lines are dropped.
    const FEED_KEY = "aether_console_feed", FEED_MAX = 12, FEED_TTL = 120000
    const clock = t => { const d = new Date(t || Date.now()); return [d.getHours(), d.getMinutes(), d.getSeconds()].map(v => String(v).padStart(2, "0")).join(":") }
    const renderLine = (t, tag, color, msg) => {
      if (!feedEl) return
      const el = doc.createElement("div"); el.className = "line"
      el.innerHTML = `<span class="ts">${clock(t)}</span><span class="tag" style="color:${color}">${tag}</span><span>${msg}</span>`
      feedEl.appendChild(el); while (feedEl.children.length > 7) feedEl.removeChild(feedEl.firstChild)
    }
    const feed = (tag, color, msg) => {
      const t = Date.now()
      renderLine(t, tag, color, msg)
      try {
        const arr = JSON.parse(localStorage.getItem(FEED_KEY) || "[]")
        arr.push({ t, tag, color, msg })
        while (arr.length > FEED_MAX) arr.shift()
        localStorage.setItem(FEED_KEY, JSON.stringify(arr))
      } catch (_e) { /* private mode / disabled storage — feed just won't persist */ }
    }
    const restoreFeed = () => {
      try {
        const cutoff = Date.now() - FEED_TTL
        JSON.parse(localStorage.getItem(FEED_KEY) || "[]")
          .filter(e => e.t > cutoff)
          .forEach(e => renderLine(e.t, e.tag, e.color, e.msg))
      } catch (_e) { /* ignore */ }
    }
    const feedFor = {
      write: (node, c) => feed("write", C.write, `${c} write${c > 1 ? "s" : ""} → ${short(node.id)}`),
      ae: (node, c) => feed("anti-ent", C.ae, `anti-entropy ×${c} ← ${short(node.id)}`),
      repair: (node, c) => feed("repair", C.repair, `read-repair ×${c} ← ${short(node.id)}`),
      shed: (node, c) => feed("shed", C.shed, `shed ×${c} @ ${short(node.id)}`),
    }

    // scheduled spawns — spread a rate's particles across the poll window
    const bursts = []
    const schedule = (delay, fn) => bursts.push({ at: now + delay, fn })
    const runBursts = () => { for (let i = bursts.length - 1; i >= 0; i--) if (now >= bursts[i].at) bursts.splice(i, 1)[0].fn() }

    // ── colors + pre-rendered glow sprites (drawImage; no per-frame gradient alloc) ──
    const hexA = (hex, a) => {
      hex = (hex || "#000").trim(); if (hex[0] !== "#") return `rgba(63,208,191,${a})`
      if (hex.length === 4) hex = "#" + [...hex.slice(1)].map(c => c + c).join("")
      return `rgba(${parseInt(hex.slice(1, 3), 16)},${parseInt(hex.slice(3, 5), 16)},${parseInt(hex.slice(5, 7), 16)},${a})`
    }
    const sprite = color => {
      const s = doc.createElement("canvas"); s.width = s.height = 64
      const g = s.getContext("2d"); const rad = g.createRadialGradient(32, 32, 0, 32, 32, 32)
      rad.addColorStop(0, hexA(color, 1)); rad.addColorStop(0.35, hexA(color, 0.55)); rad.addColorStop(1, hexA(color, 0))
      g.fillStyle = rad; g.fillRect(0, 0, 64, 64); return s
    }
    const glowCache = {}
    const drawGlow = (color, x, y, radius, alpha) => {
      const spr = glowCache[color] || (glowCache[color] = sprite(color))
      ctx.globalAlpha = alpha; ctx.drawImage(spr, x - radius, y - radius, radius * 2, radius * 2); ctx.globalAlpha = 1
    }
    const easeInOut = t => t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2
    const fmt = v => Math.round(v).toLocaleString("en-US")

    const drawNode = n => {
      const r = Math.max(radiusOf(n), 7)
      ctx.globalCompositeOperation = "lighter"
      const col = n.up ? C.teal : C.down, alpha = n.up ? 0.9 : Math.max(n.ember, 0.12)
      drawGlow(col, n.x, n.y, r * 2.6, 0.42 * alpha)
      if (n.leader && n.halo > 0.01) {
        const hr = r + 10 + Math.sin(n.pulse) * 2.2
        ctx.strokeStyle = hexA(C.gold, 0.5 * n.halo); ctx.lineWidth = 2; ctx.beginPath(); ctx.arc(n.x, n.y, hr, 0, 6.283); ctx.stroke()
        drawGlow(C.gold, n.x, n.y, hr + 8, 0.16 * n.halo)
      }
      ctx.globalCompositeOperation = "source-over"
      ctx.beginPath(); ctx.arc(n.x, n.y, r, 0, 6.283); ctx.fillStyle = n.up ? "#0c1a1f" : "#160e0e"; ctx.fill()
      ctx.lineWidth = 1.6; ctx.strokeStyle = n.up ? hexA(n.leader ? C.gold : C.teal, 0.85) : hexA(C.down, Math.max(n.ember, 0.2)); ctx.stroke()
      ctx.textAlign = "center"; ctx.fillStyle = n.up ? C.ink : hexA(C.muted, 0.7); ctx.font = "600 12px " + V("--mono"); ctx.fillText(short(n.id), n.x, n.y - r - 9)
      ctx.fillStyle = n.up ? hexA(C.muted, 0.95) : hexA(C.faint, 0.9); ctx.font = "11px " + V("--mono"); ctx.fillText(n.up ? fmt(n.count) : "down", n.x, n.y + r + 16)
    }

    const readouts = () => {
      const up = upNodes().length
      roNodes && (roNodes.textContent = offline || !nodes.length ? "—" : up + " / " + nodes.length)
      roOps && (roOps.textContent = offline ? "—" : String(opsPerSec))
    }

    let raf = 0, last = 0, running = false
    const frame = ts => {
      if (!running) return
      const dt = Math.min((ts - last) / 1000 || 0, 0.05); last = ts; now = ts
      ctx.globalCompositeOperation = "source-over"; ctx.fillStyle = hexA(C.field0(), 0.30); ctx.fillRect(0, 0, W, H)
      ctx.globalCompositeOperation = "lighter"
      drawGlow(C.teal, cx, cy, R * 1.5, 0.05)
      ctx.globalCompositeOperation = "source-over"; ctx.strokeStyle = hexA(C.teal, 0.14); ctx.lineWidth = 1; ctx.beginPath(); ctx.arc(cx, cy, R, 0, 6.283); ctx.stroke()
      runBursts()
      ctx.globalCompositeOperation = "lighter"
      for (let i = parts.length - 1; i >= 0; i--) {
        const p = parts[i]; p.t += p.sp * dt; if (p.t >= 1) { parts.splice(i, 1); continue }
        if (p.fade) {
          const e = easeInOut(p.t), a = 1 - p.t, sz = p.size * (1 - p.t * 0.7)
          const fx = p.x0 + (p.x1 - p.x0) * e, fy = p.y0 + (p.y1 - p.y0) * e
          ctx.strokeStyle = hexA(p.color, 0.35 * a); ctx.lineWidth = sz * 0.8; ctx.beginPath(); ctx.moveTo(p.px, p.py); ctx.lineTo(fx, fy); ctx.stroke()
          drawGlow(p.color, fx, fy, sz * 3, 0.85 * a); p.px = fx; p.py = fy; continue
        }
        const [x, y] = pointAt(p, easeInOut(p.t))
        ctx.strokeStyle = hexA(p.color, 0.5); ctx.lineWidth = p.size * 0.9; ctx.beginPath(); ctx.moveTo(p.px, p.py); ctx.lineTo(x, y); ctx.stroke()
        drawGlow(p.color, x, y, p.size * 3.2, 0.95); p.px = x; p.py = y
      }
      for (const n of nodes) { n.pulse += dt * 2.2; if (n.leader && n.halo < 1) n.halo = Math.min(1, n.halo + dt * 1.6); if (!n.up && n.ember > 0.12) n.ember = Math.max(0.12, n.ember - dt * 0.5); drawNode(n) }
      readouts()
      raf = requestAnimationFrame(frame)
    }
    const staticFrame = () => {
      if (!W || !H) return
      ctx.globalCompositeOperation = "source-over"; ctx.fillStyle = C.field0(); ctx.fillRect(0, 0, W, H)
      ctx.strokeStyle = hexA(C.teal, 0.14); ctx.lineWidth = 1; ctx.beginPath(); ctx.arc(cx, cy, R, 0, 6.283); ctx.stroke()
      for (const n of nodes) drawNode(n)
      readouts()
    }

    // ── apply real topology + drive particles from real op RATES ──
    const POLL_MS = 1400
    // Spread `count` particles (capped) across the poll window so flow is steady.
    // The cap keeps the browser safe at any op volume — density conveys load.
    const emitRate = (peers, node, op, count, dir, cap) => {
      if (!count || count <= 0 || !peers.length) return
      const n = Math.min(count, cap)
      for (let k = 0; k < n; k++) schedule((k / n) * POLL_MS, () => {
        const peer = peers[(Math.random() * peers.length) | 0]
        dir === "in" ? spawn(peer, node, op) : spawn(node, peer, op)
      })
      feedFor[op] && feedFor[op](node, count)
    }
    const emitShed = (node, count) => {
      if (!node || !count || count <= 0) return
      const n = Math.min(count, 12)
      for (let k = 0; k < n; k++) schedule((k / n) * POLL_MS, () => spawnShed(node))
      feedFor.shed(node, count)
    }
    const applyTopology = d => {
      const prev = new Map(nodes.map(n => [n.id, n]))
      const sorted = d.nodes.slice().sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
      const next = sorted.map((nv, i) => {
        const p = prev.get(nv.name)
        return {
          id: nv.name, i, up: nv.up, leader: !!nv.leader, count: nv.objects || 0,
          pulse: p ? p.pulse : Math.random() * 6.28,
          halo: nv.leader ? (p ? p.halo : 0) : 0,
          ember: nv.up ? 0 : (p && !p.up ? Math.max(p.ember, 0.12) : 1),
          x: p ? p.x : cx, y: p ? p.y : cy, ang: 0,
        }
      })
      nodes.length = 0; next.forEach(n => nodes.push(n))
      N = Math.max(nodes.length, 1); nodes.forEach((n, i) => n.i = i); layout()

      // writes land ON a node (in); repairs it initiates flow OUT; sheds dissolve.
      const up = next.filter(n => n.up)
      let total = 0
      sorted.forEach(nv => {
        const target = next.find(n => n.id === nv.name), r = nv.rates
        if (!target || !target.up || !r) return
        total += (r.put || 0) + (r.repair || 0) + (r.read_repair || 0) + (r.shed || 0)
        const peers = up.filter(n => n !== target)
        emitRate(peers, target, "write", r.put, "in", 30)
        emitRate(peers, target, "ae", r.repair, "out", 30)
        emitRate(peers, target, "repair", r.read_repair, "out", 30)
        emitShed(target, r.shed)
      })
      opsPerSec = Math.round(total / (POLL_MS / 1000))
      if (roLeader) roLeader.textContent = d.leader ? short(d.leader) : "—"
    }

    this.handleEvent("cluster", d => {
      if (!d) return
      if (!d.connected) {
        // Lost every configured node — say so instead of freezing on the last snapshot.
        if (!offline) { offline = true; feed("cluster", C.down, "cluster unreachable — reconnecting…"); roLeader && (roLeader.textContent = "—") }
      } else {
        if (offline) { offline = false; feed("cluster", C.teal, "reconnected") }
        applyTopology(d)
      }
      if (reduced) staticFrame()
    })

    // ── wiring ──
    this._onResize = () => { resize(); if (reduced) staticFrame() }
    window.addEventListener("resize", this._onResize)

    resize()
    restoreFeed()
    this._stop = () => { running = false; cancelAnimationFrame(raf) }
    if (reduced) staticFrame()
    else { running = true; raf = requestAnimationFrame(t => { last = t; frame(t) }) }
  },

  destroyed() {
    this._stop && this._stop()
    window.removeEventListener("resize", this._onResize)
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ClusterField },
})
liveSocket.connect()
window.liveSocket = liveSocket
