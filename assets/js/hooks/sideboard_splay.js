// SideboardSplay — dynamically spaces sideboard cards to fill the container
// width, capped at the same column gap used in the deck view above (card
// width + 12px gap). Falls back to tighter overlap when there are many cards.

const CARD_GAP = 12 // gap-3 in Tailwind = 12px — matches deck column spacing

export const SideboardSplay = {
  mounted() {
    this._layout()
    this._observer = new ResizeObserver(() => this._layout())
    this._observer.observe(this.el)
  },

  destroyed() {
    this._observer?.disconnect()
  },

  _layout() {
    const container = this.el.querySelector("[data-splay-container]")
    if (!container) return

    const cards = Array.from(container.children)
    if (cards.length === 0) return

    const cardWidth = cards[0].offsetWidth
    if (cardWidth === 0) return // not yet painted

    if (cards.length === 1) {
      cards[0].style.marginLeft = "0px"
      return
    }

    const containerWidth = this.el.offsetWidth
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
