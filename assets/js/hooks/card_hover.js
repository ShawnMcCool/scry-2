// CardHover — shows a large card preview near the cursor on hover.
// Attached to <img> elements via phx-hook="CardHover".
// Uses a shared popup element (#card-hover-popup) in root layout.

export const CardHover = {
  mounted() {
    this.popup = document.getElementById("card-hover-popup")
    this.popupImg = document.getElementById("card-hover-popup-img")

    this.el.addEventListener("mouseenter", (e) => {
      const src = this.el.dataset.cardSrc || this.el.src
      if (!src) return

      this.popupImg.src = src
      this.popupImg.alt = this.el.dataset.cardAlt || this.el.alt || ""
      this.popup.style.display = "block"
      this._position(e)
    })

    this.el.addEventListener("mousemove", (e) => {
      this._position(e)
    })

    this.el.addEventListener("mouseleave", () => {
      this.popup.style.display = "none"
      this.popupImg.src = ""
    })
  },

  destroyed() {
    this.popup.style.display = "none"
    this.popupImg.src = ""
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
