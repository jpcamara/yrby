# An agent as a collaborator

`plan_runner.rb` is a Ruby process that takes part in a shared document the
same way a browser does. A person writes a plan, one step per line, in a
collaborative document. The runner executes the steps and writes its progress
to a second document. Both are ordinary `collaborative_document` attributes,
so a `<yrby-document>` element shows each one live.

The part that matters is when the runner reads. It does not load the plan once
and work from a copy. Before every step it reloads the document from storage.
Every browser edit is recorded there before yrby acknowledges it, so the store
is the shared truth, and an edit made while step one was running is what step
two executes. If the step it is running changes underneath it, it runs that
step again with the new text.

```ruby
runner = PlanRunner.new(
  plan: post.collaborative_document(:plan),
  log: post.collaborative_document(:agent_log),
  executor: ->(step) { Agent.perform(step) },
)
runner.run
```

Writing back goes through `collaborative_document(name).edit`, which records
the change and broadcasts it, so the log fills in on every open screen.

The proof lives in the gem's browser regression (`npm run test:browser` in
`packages/client`): a real Chrome types a plan, starts the runner, edits the
second step while the first is running, and the log shows the edited step
being executed.
