// CardHover — shows a large card preview near the cursor on hover.
// Attached via phx-hook="CardHover" to <img> elements and to text rows
// carrying data-card-src.
//
// The popup only appears once the preview image has actually loaded:
// a card whose image isn't cached server-side yet shows nothing (the
// image route 404s), and the hover starts working as soon as the
// background download completes — no re-render needed. This lets
// templates attach the hook unconditionally. Never gate phx-hook on
// image readiness server-side: adding phx-hook to an already-rendered
// element in a later patch does not mount the hook.

export const CardHover = {
  mounted() {
    this.popup = document.getElementById("card-hover-popup")
    this.popupImg = document.getElementById("card-hover-popup-img")
    this.hovering = false

    this.el.addEventListener("mouseenter", (e) => {
      const src = this.el.dataset.cardSrc || this.el.src
      if (!src) return

      this.hovering = true
      this.lastEvent = e

      const show = () => {
        if (!this.hovering) return
        this.popup.style.display = "block"
        this._position(this.lastEvent)
      }

      this.popupImg.onload = show
      this.popupImg.onerror = () => { this.popup.style.display = "none" }
      this.popupImg.alt = this.el.dataset.cardAlt || this.el.alt || ""

      const loaded = this.popupImg.complete && this.popupImg.naturalWidth > 0

      if (this.popupImg.getAttribute("src") !== src) {
        this.popupImg.src = src
      } else if (loaded) {
        // Same card as the last hover and already loaded — onload
        // won't fire again.
        show()
      } else {
        // The last attempt at this src failed (e.g. 404 before the
        // image was cached). The file may exist now — retry the fetch.
        this.popupImg.removeAttribute("src")
        this.popupImg.src = src
      }
    })

    this.el.addEventListener("mousemove", (e) => {
      this.lastEvent = e
      if (this.popup.style.display === "block") this._position(e)
    })

    this.el.addEventListener("mouseleave", () => this._hide())
  },

  destroyed() {
    if (this.popup) this._hide()
  },

  _hide() {
    this.hovering = false
    this.popup.style.display = "none"
    this.popupImg.onload = null
    this.popupImg.onerror = null
  },

  _position(e) {
    const offset = 20
    const rect = this.popup.getBoundingClientRect()
    const popupW = rect.width || 250
    const popupH = rect.height || 350

    // Horizontal: prefer right of cursor, fall back to left if too close to right edge
    let x = e.clientX + offset
    if (x + popupW > window.innerWidth) x = e.clientX - popupW - offset
    if (x < 0) x = 0

    // Vertical: center on cursor, clamp to viewport edges
    let y = e.clientY - popupH / 2
    if (y < 0) y = 0
    if (y + popupH > window.innerHeight) y = window.innerHeight - popupH

    this.popup.style.left = x + "px"
    this.popup.style.top = y + "px"
  }
}
