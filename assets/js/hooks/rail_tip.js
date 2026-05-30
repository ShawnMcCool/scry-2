// RailTip — shows a styled tooltip pill to the right of a sidebar item on hover.
// Attached to collapsed-rail links/buttons via phx-hook="RailTip". The label
// comes from the element's data-tip attribute; when data-tip is absent (the
// expanded rail, where labels render inline) the hook is a no-op.
//
// Uses a single shared #rail-tooltip element in the root layout so the pill
// renders at the document level and is never clipped by the sidebar's
// overflow-y-auto — the same pattern as the CardHover popup.

export const RailTip = {
  mounted() {
    this.tip = document.getElementById("rail-tooltip")

    this._show = () => {
      const label = this.el.dataset.tip
      if (!label || !this.tip) return

      this.tip.textContent = label
      this.tip.style.display = "block"

      const anchor = this.el.getBoundingClientRect()
      const gap = 10
      this.tip.style.left = anchor.right + gap + "px"
      // Vertically centre the pill on the icon (measure after display:block).
      const top = anchor.top + anchor.height / 2 - this.tip.offsetHeight / 2
      this.tip.style.top = Math.max(4, top) + "px"

      // Next frame so the opacity/transform transition actually plays.
      requestAnimationFrame(() => this.tip.setAttribute("data-show", "true"))
    }

    this._hide = () => {
      if (!this.tip) return
      this.tip.removeAttribute("data-show")
      this.tip.style.display = "none"
    }

    this.el.addEventListener("mouseenter", this._show)
    this.el.addEventListener("mouseleave", this._hide)
    // Hide immediately on click so it doesn't linger through a navigation.
    this.el.addEventListener("click", this._hide)
  },

  destroyed() {
    this._hide && this._hide()
  }
}
