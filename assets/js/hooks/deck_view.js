// DeckView — coordinates the deck card grid and sideboard splay layout.
//
// In compact mode, columns are flex:1 so card width is determined by the
// browser. This hook measures the rendered column width and:
//   1. Sets sideboard card widths to match the main deck card width
//   2. Calculates sideboard splay spacing to fill the deck grid width
//
// In large mode, columns have fixed max-widths and the sideboard uses
// the same fixed card width (w-28 = 7rem).

const CARD_GAP = 12 // gap-3 = 12px

export const DeckView = {
  mounted() {
    this._observer = new ResizeObserver(() => this._layout())
    this._observer.observe(this.el)
    const grid = this.el.querySelector("[data-deck-grid]")
    if (grid) this._observer.observe(grid)
    this._layout()
  },

  updated() {
    // Re-run after LiveView patches (e.g. mode switch)
    this._layout()
  },

  destroyed() {
    this._observer?.disconnect()
  },

  _layout() {
    this._layoutSideboard()
  },

  // Returns the rendered width of one CMC column in the deck grid.
  _columnWidth() {
    const grid = this.el.querySelector("[data-deck-grid]")
    if (!grid) return null
    const firstCol = grid.firstElementChild
    if (!firstCol) return null
    const width = firstCol.offsetWidth
    return width > 0 ? width : null
  },

  // Returns the total content width of the deck grid (all columns + gaps).
  _deckContentWidth() {
    const grid = this.el.querySelector("[data-deck-grid]")
    if (!grid) return null
    const cols = Array.from(grid.children)
    if (cols.length === 0) return null
    const colWidth = cols[0].offsetWidth
    if (colWidth === 0) return null
    return cols.length * colWidth + (cols.length - 1) * CARD_GAP
  },

  _layoutSideboard() {
    const splayContainer = this.el.querySelector("[data-splay-container]")
    if (!splayContainer) return

    const cards = Array.from(splayContainer.children)
    if (cards.length === 0) return

    const colWidth = this._columnWidth()
    const deckWidth = this._deckContentWidth()

    // Set sideboard card widths to match main deck column width
    if (colWidth) {
      cards.forEach(card => {
        card.style.width = colWidth + "px"
      })
    }

    const cardWidth = colWidth || cards[0].offsetWidth
    if (cardWidth === 0) return

    // Constrain sideboard container to deck grid width
    const splayEl = this.el.querySelector("[data-sideboard-splay]")
    if (splayEl && deckWidth) {
      splayEl.style.maxWidth = deckWidth + "px"
    }

    if (cards.length === 1) {
      cards[0].style.marginLeft = "0px"
      return
    }

    const containerWidth = deckWidth || this.el.offsetWidth
    const maxOffset = cardWidth + CARD_GAP

    // Spread cards across the container; cap at max gap
    const optimalOffset = (containerWidth - cardWidth) / (cards.length - 1)
    const offset = Math.min(optimalOffset, maxOffset)
    const marginLeft = offset - cardWidth

    cards.forEach((card, index) => {
      card.style.marginLeft = index === 0 ? "0px" : `${marginLeft}px`
    })
  },
}
