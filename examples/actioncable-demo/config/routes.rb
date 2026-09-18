Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  get "docs/:id", to: "documents#show", as: :document
  get "docs/:id/lexxy", to: "documents#lexxy", as: :document_lexxy
  # A Rack endpoint: under Falcon the answer streams while the agent runs
  # (see AgentInvite); under Puma it is documents#agent.
  post "docs/:id/agent", to: AgentInvite.new(ReviewAgent, action: :agent), as: :document_agent
  get "docs/:id/rhino", to: "documents#rhino", as: :document_rhino
  # "Opaque state" demos: the same DocumentChannel, different Yjs shapes.
  get "docs/:id/codemirror", to: "documents#codemirror", as: :document_codemirror
  get "docs/:id/markdown", to: "documents#markdown", as: :document_markdown
  post "docs/:id/markdown_agent", to: "documents#markdown_agent", as: :document_markdown_agent
  get "docs/:id/whiteboard", to: "documents#whiteboard", as: :document_whiteboard
  get "docs/:id/kanban", to: "documents#kanban", as: :document_kanban
  get "docs/:id/forms", to: "documents#forms", as: :document_forms
  get "docs/:id/spreadsheet", to: "documents#spreadsheet", as: :document_spreadsheet
  get "docs/:id/sudoku", to: "documents#sudoku", as: :document_sudoku
  # The checker's invite takes the agent's shape: a stream under Falcon,
  # documents#sudoku_checker under Puma.
  post "docs/:id/sudoku/checker", to: AgentInvite.new(SudokuPeer, action: :sudoku_checker, suffix: ":sudoku"),
                                  as: :document_sudoku_checker
  get "docs/:id/content", to: "documents#content", as: :document_content
  get "docs/:id/audit", to: "documents#audit", as: :document_audit
  # DEMO/TEST ONLY — never mount in production. One anonymous POST can wipe a
  # document's durable history (reset=1) or inject a per-write sleep (delay_ms)
  # that starves the worker pool. The e2e suites depend on it, so it's gated by
  # environment rather than removed.
  unless Rails.env.production?
    post "docs/:id/audit/control", to: "documents#audit_control", as: :document_audit_control
  end

  root to: redirect("/docs/demo")
end
