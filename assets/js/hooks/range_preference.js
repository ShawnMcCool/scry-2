const STORAGE_KEY = "scry2:rank_range"

export const RangePreference = {
  mounted() {
    this.saveRange()
  },

  updated() {
    this.saveRange()
  },

  saveRange() {
    const range = this.el.dataset.range
    if (range) localStorage.setItem(STORAGE_KEY, range)
  },
}

export function storedRangePreference() {
  return localStorage.getItem(STORAGE_KEY)
}
