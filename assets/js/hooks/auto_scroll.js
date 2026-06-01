// Sticks scroll to bottom while content grows; respects manual user scroll.
// Once user scrolls away from bottom, auto-scroll pauses until they return
// near the bottom (within `threshold` px) OR the server pushes a
// `concilio:scroll_to_bottom` event (e.g. user sent a message), which
// force-re-engages and scrolls.
export const AutoScroll = {
  mounted() {
    this.threshold = 16
    this.pinned = true
    this.scrollToBottom()

    this.onScroll = () => {
      const distance =
        this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this.pinned = distance <= this.threshold
    }
    this.el.addEventListener("scroll", this.onScroll, {passive: true})

    this.handleEvent("concilio:scroll_to_bottom", () => {
      this.pinned = true
      this.scrollToBottom()
    })
  },
  updated() {
    if (this.pinned) this.scrollToBottom()
  },
  destroyed() {
    if (this.onScroll) this.el.removeEventListener("scroll", this.onScroll)
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}
