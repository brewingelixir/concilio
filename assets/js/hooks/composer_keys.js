const storageKey = () => `concilio:composer:${window.location.pathname}`

const safeStorage = () => {
  try { return window.sessionStorage } catch (_) { return null }
}

const saveDraft = (value) => {
  const s = safeStorage()
  if (!s) return
  try {
    if (value && value.length > 0) s.setItem(storageKey(), value)
    else s.removeItem(storageKey())
  } catch (_) { /* quota or privacy mode — ignore */ }
}

const loadDraft = () => {
  const s = safeStorage()
  if (!s) return ""
  try { return s.getItem(storageKey()) || "" } catch (_) { return "" }
}

export const ComposerKeys = {
  mounted() {
    this.onKeydown = (e) => {
      if (e.key !== "Enter") return
      if (e.isComposing || e.keyCode === 229) return
      if (e.shiftKey || e.altKey) return
      e.preventDefault()
      const form = this.el.closest("form")
      if (form) form.requestSubmit()
    }
    this.el.addEventListener("keydown", this.onKeydown)

    this.onInput = () => saveDraft(this.el.value)
    this.el.addEventListener("input", this.onInput)

    this.onSet = (payload) => {
      const text = (payload && typeof payload.text === "string") ? payload.text : ""
      this.el.value = text
      saveDraft(text)
      this.el.dispatchEvent(new Event("input", {bubbles: true}))
    }
    this.handleEvent("concilio:set_composer", this.onSet)

    // Restore draft only if the LV-rendered value is empty — never
    // overwrite text the server pushed (e.g. quote_council insertions).
    const draft = loadDraft()
    if (draft && (this.el.value || "").length === 0) {
      this.el.value = draft
      this.el.dispatchEvent(new Event("input", {bubbles: true}))
    }
  },
  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
    if (this.onInput) this.el.removeEventListener("input", this.onInput)
  }
}
