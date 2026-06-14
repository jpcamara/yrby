Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  get "docs/:id", to: "documents#show", as: :document
  get "docs/:id/content", to: "documents#content", as: :document_content
  get "docs/:id/audit", to: "documents#audit", as: :document_audit
  post "docs/:id/audit/control", to: "documents#audit_control", as: :document_audit_control

  root to: redirect("/docs/demo")
end
