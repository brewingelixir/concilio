function format(ms) {
  if (ms < 0) ms = 0
  const s = ms / 1000
  if (s < 60) return `${s.toFixed(1)}s`
  const mins = Math.floor(s / 60)
  const rem = Math.floor(s - mins * 60)
  return `${mins}m ${rem}s`
}

export const ElapsedTimer = {
  mounted() {
    this.start()
  },
  updated() {
    // restart if the start timestamp changed
    const start = parseInt(this.el.dataset.startMs, 10)
    if (Number.isFinite(start) && start !== this.startMs) {
      this.stop()
      this.start()
    }
  },
  destroyed() {
    this.stop()
  },
  start() {
    const start = parseInt(this.el.dataset.startMs, 10)
    if (!Number.isFinite(start)) return
    this.startMs = start
    const tick = () => {
      this.el.textContent = format(Date.now() - this.startMs)
    }
    tick()
    this.timer = setInterval(tick, 500)
  },
  stop() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  }
}
