// ClipboardCopy — phx-hook that copies the element's `data-copy-text`
// to the OS clipboard on click and pushes a `copied` event back to the
// LiveView so it can flash a confirmation.
//
// Used by the deck-detail "Copy to MTGA" button. MTGA's deck builder
// has an in-game Import button that pastes from clipboard, so the whole
// re-import flow is: click here → alt-tab to MTGA → click Import.

export const ClipboardCopy = {
  mounted() {
    this.handler = (event) => {
      event.preventDefault()
      const text = this.el.dataset.copyText
      if (!text) return

      const finish = (ok) => {
        if (ok) {
          this.pushEventTo(this.el, "copied", {})
        } else {
          this.pushEventTo(this.el, "copy_failed", {})
        }
      }

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(() => finish(true), () => finish(false))
      } else {
        // Fallback path (older browsers, non-secure contexts).
        const textarea = document.createElement("textarea")
        textarea.value = text
        textarea.setAttribute("readonly", "")
        textarea.style.position = "absolute"
        textarea.style.left = "-9999px"
        document.body.appendChild(textarea)
        textarea.select()
        try {
          finish(document.execCommand("copy"))
        } catch (_e) {
          finish(false)
        } finally {
          document.body.removeChild(textarea)
        }
      }
    }
    this.el.addEventListener("click", this.handler)
  },
  destroyed() {
    if (this.handler) this.el.removeEventListener("click", this.handler)
  },
}
