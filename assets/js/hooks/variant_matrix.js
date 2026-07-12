// Column crosshair for the netdeck variant matrix (UIDR-014).
//
// Rows highlight via CSS :hover; columns can't, so this hook washes every
// cell sharing the hovered cell's column index. Cells opt in with a bare
// `data-col` attribute — the index is their position among the row's
// data-col cells, so server-rendered markup stays free of counters.
export const VariantMatrix = {
  mounted() {
    this.el.addEventListener("mouseover", (event) => {
      const cell = event.target.closest("[data-col]")
      if (!cell) return
      const index = this.columnIndex(cell)
      if (index !== this.highlighted) this.highlight(index)
    })
    this.el.addEventListener("mouseleave", () => this.highlight(null))
  },

  columnIndex(cell) {
    const row = cell.closest("tr")
    return Array.prototype.indexOf.call(row.querySelectorAll("[data-col]"), cell)
  },

  highlight(index) {
    this.highlighted = index
    this.el.querySelectorAll("tr").forEach((row) => {
      row.querySelectorAll("[data-col]").forEach((cell, cellIndex) => {
        cell.classList.toggle("bg-base-content/5", cellIndex === index)
      })
    })
  },
}
