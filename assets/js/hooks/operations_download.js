// assets/js/hooks/operations_download.js
//
// Hook for the Operations page error section.
// Handles the operations:download push_event to trigger a JSON file download.

export const OperationsDownload = {
  mounted() {
    this.handleEvent("operations:download", ({ filename, content }) => {
      const blob = new Blob([content], { type: "application/json;charset=utf-8" })
      const url = URL.createObjectURL(blob)
      const anchor = document.createElement("a")
      anchor.href = url
      anchor.download = filename
      document.body.appendChild(anchor)
      anchor.click()
      document.body.removeChild(anchor)
      URL.revokeObjectURL(url)
    })
  },
}
