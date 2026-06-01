// Persist a boolean toggle in localStorage and push the saved value back to
// the LiveView on mount so the server reflects user preference across reloads.
//
// Usage on the LV side:
//
//   <div phx-hook="LocalStorageToggle"
//        data-storage-key="concilio:show-examples"
//        data-default="true">
//     <input type="checkbox"
//            data-toggle-target="show-examples"
//            phx-click="toggle_examples"
//            phx-value-value={(!@show_examples) |> to_string()} />
//   </div>
//
// `toggle_examples` event payload arrives with `value: "true"|"false"`.
// The hook does two things:
//   1. On mount, read the stored value and push `toggle_examples` if it
//      differs from server default.
//   2. On checkbox change, write the new value back to localStorage.

export const LocalStorageToggle = {
  mounted() {
    const key = this.el.dataset.storageKey
    if (!key) return

    const def = (this.el.dataset.default || "true") === "true"
    const stored = localStorage.getItem(key)
    const current = stored === null ? def : stored === "true"

    if (current !== def) {
      this.pushEvent("toggle_examples", { value: current ? "true" : "false" })
    }

    this.el.addEventListener("change", (e) => {
      const t = e.target
      if (!(t instanceof HTMLInputElement)) return
      if (t.type !== "checkbox") return
      localStorage.setItem(key, t.checked ? "true" : "false")
    })
  },
}
