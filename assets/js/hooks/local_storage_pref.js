// Persist a `<select>` value to localStorage and reapply on mount.
//
// Usage:
//   <select phx-hook="LocalStoragePref"
//           data-storage-key="concilio:topology-layout"
//           data-default="dagre"
//           name="layout"
//           ...phx-change handler on enclosing form...>
//     <option value="dagre" selected>...</option>
//   </select>
//
// On mount the hook reads localStorage; if a stored value differs from the
// current select.value it sets the select and dispatches a `change` event
// (which fires the parent form's phx-change handler). On every change the
// hook writes the new value back.

export const LocalStoragePref = {
  mounted() {
    const key = this.el.dataset.storageKey
    if (!key) return

    const stored = localStorage.getItem(key)
    if (stored !== null && stored !== this.el.value) {
      // Verify the stored value is one of the available options before applying.
      const options = Array.from(this.el.options).map((o) => o.value)
      if (options.includes(stored)) {
        this.el.value = stored
        this.el.dispatchEvent(new Event("change", { bubbles: true }))
      }
    }

    this.el.addEventListener("change", () => {
      localStorage.setItem(key, this.el.value)
    })
  },
}
