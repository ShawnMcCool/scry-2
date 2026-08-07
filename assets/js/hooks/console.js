// assets/js/hooks/console.js
//
// LiveView hook for the full-page `/console` route. Handles:
// - Client-side text search via data-message attributes on log entries
// - Copy to clipboard (console:copy push_event)
// - Download as .log file (console:download push_event)
// - `/` focuses the search input
// - Keeping newly-prepended entries visible when scrolled to the top

export const Console = {
  mounted() {
    this._root = this.el // <div id="console-page">
    this._searchInput = this._root.querySelector("[data-console-search]")
    this._entriesContainer = this._root.querySelector("#console-entries")

    this._onKeyDown = (event) => this._handleKeyDown(event)
    this._onSearchInput = () => this._applyClientSearch()
    this._onCopy = ({ content }) => this._copy(content)
    this._onDownload = ({ filename, content }) => this._download(filename, content)

    this._root.addEventListener("keydown", this._onKeyDown)
    this._searchInput?.addEventListener("input", this._onSearchInput)

    this.handleEvent("console:copy", this._onCopy)
    this.handleEvent("console:download", this._onDownload)

    // After LiveView inserts new entries: re-apply the client search filter,
    // and if the user is already scrolled to the top keep them there so new
    // entries (inserted at position 0) remain visible.
    this._observer = new MutationObserver(() => {
      if (this._searchInput?.value) {
        this._applyClientSearch()
      }
      this._maintainTopScroll()
    })
    if (this._entriesContainer) {
      this._observer.observe(this._entriesContainer, {
        childList: true,
        subtree: false,
      })
    }
  },

  destroyed() {
    this._root?.removeEventListener("keydown", this._onKeyDown)
    this._searchInput?.removeEventListener("input", this._onSearchInput)
    this._observer?.disconnect()
  },

  _handleKeyDown(event) {
    if (event.key === "/" && document.activeElement !== this._searchInput) {
      event.preventDefault()
      this._searchInput?.focus()
    }
  },

  _applyClientSearch() {
    if (!this._entriesContainer) return

    const query = (this._searchInput?.value || "").toLowerCase().trim()
    const entries = this._entriesContainer.querySelectorAll("[data-message]")

    entries.forEach((node) => {
      const message = node.dataset.message || ""
      const matches = query === "" || message.includes(query)
      node.style.display = matches ? "" : "none"
    })
  },

  // If the user was already at (or very near) the top of the entries list,
  // snap back to the top after new entries are prepended. This keeps freshly
  // arriving log lines visible without disturbing users who scrolled down to
  // read older entries.
  //
  // Threshold of 10 px absorbs sub-pixel rounding on hi-DPI displays.
  _maintainTopScroll() {
    if (!this._entriesContainer) return
    if (this._entriesContainer.scrollTop <= 10) {
      this._entriesContainer.scrollTop = 0
    }
  },

  _copy(content) {
    if (!navigator.clipboard) {
      console.error("[console] clipboard API unavailable")
      return
    }
    navigator.clipboard.writeText(content).catch((error) => {
      console.error("[console] copy failed:", error)
    })
  },

  _download(filename, content) {
    const blob = new Blob([content], { type: "text/plain;charset=utf-8" })
    const url = URL.createObjectURL(blob)
    const anchor = document.createElement("a")
    anchor.href = url
    anchor.download = filename
    document.body.appendChild(anchor)
    anchor.click()
    document.body.removeChild(anchor)
    URL.revokeObjectURL(url)
  },
}
