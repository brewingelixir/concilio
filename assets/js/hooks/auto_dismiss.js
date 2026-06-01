export const AutoDismiss = {
  mounted() {
    const ms = parseInt(this.el.dataset.dismissAfter, 10)
    if (!Number.isFinite(ms) || ms <= 0) return
    this.timer = setTimeout(() => this.el.click(), ms)
  },
  destroyed() {
    if (this.timer) clearTimeout(this.timer)
  }
}
