// SideboardSplay — dynamically spaces sideboard cards to fill the container
// width, capped at the same column gap used in the deck view above (card
// width + 12px gap). Falls back to tighter overlap when there are many cards.
//
// Constrains sideboard width to match the deck grid's actual content width
// (sum of CMC column widths + gaps), not the deck grid container width, which
// can be wider than the columns when the deck doesn't fill the available space.

const CARD_GAP = 12 // gap-3 in Tailwind = 12px — matches deck column spacing

export const SideboardSplay = {
  mounted() {
    this._deckGrid = this.el.parentElement?.querySelector("[data-deck-grid]") ?? null
    this._observer = new ResizeObserver(() => this._layout())
    this._observer.observe(this.el)
    if (this._deckGrid) this._observer.observe(this._deckGrid)
    this._layout()
  },

  destroyed() {
    this._observer?.disconnect()
  },

  // Returns the actual rendered width of the CMC columns inside the deck grid,
  // which may be narrower than the deck grid container itself.
  _deckContentWidth() {
    if (!this._deckGrid) return null
    const cols = Array.from(this._deckGrid.children)
    if (cols.length === 0) return null
    const colWidth = cols[0].offsetWidth
    if (colWidth === 0) return null
    return cols.length * colWidth + (cols.length - 1) * CARD_GAP
  },

  _layout() {
    const container = this.el.querySelector("[data-splay-container]")
    if (!container) return

    const cards = Array.from(container.children)
    if (cards.length === 0) return

    const cardWidth = cards[0].offsetWidth
    if (cardWidth === 0) return // not yet painted

    // Constrain sideboard to the deck grid's actual column content width
    const deckWidth = this._deckContentWidth()
    if (deckWidth) {
      this.el.style.maxWidth = deckWidth + "px"
    }

    if (cards.length === 1) {
      cards[0].style.marginLeft = "0px"
      return
    }

    const containerWidth = deckWidth ?? this.el.offsetWidth
    const maxOffset = cardWidth + CARD_GAP

    // Spread all cards across the full container width; cap at max so
    // a small sideboard doesn't leave huge gaps between cards.
    const optimalOffset = (containerWidth - cardWidth) / (cards.length - 1)
    const offset = Math.min(optimalOffset, maxOffset)
    const marginLeft = offset - cardWidth // negative = overlap

    cards.forEach((card, index) => {
      card.style.marginLeft = index === 0 ? "0px" : `${marginLeft}px`
    })
  },
}
