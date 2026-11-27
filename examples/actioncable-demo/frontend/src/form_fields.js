// The yrby-forms page. Importing the package registers <collaborative-field>
// and <yrby-document>, and the attributes the server rendered do the rest.
import "yrby-forms"

const status = document.getElementById("status")
document.addEventListener("yrby:synced", ({ target }) => {
  status.textContent = `synced as ${target.dataset.userName}`
})
document.addEventListener("yrby:error", () => {
  status.textContent = "disconnected"
})
