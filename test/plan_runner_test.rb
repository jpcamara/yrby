# frozen_string_literal: true

require_relative "document_channel_test"
require_relative "../examples/agent/plan_runner"

# The runner reads each step from storage right before it runs it, so a person
# editing the plan while the agent works changes what the agent does next.
# The executor stands in for the person: it edits the plan during a step, the
# way a browser would while the agent is busy.
class PlanRunnerTest < ActionCable::Channel::TestCase
  tests Y::DocumentChannel

  def setup
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
    @page = DocumentChannelTest::Page.create!(title: "plan")
    @plan = @page.collaborative_document(:plan)
    @log = @page.collaborative_document(:agent_log)
    @plan.edit { |doc| doc.get_text("content").push("collect metrics\nverify\nreport\n") }
  end

  def teardown
    DocumentChannelTest::Page.delete_all
  end

  def test_an_edit_made_during_one_step_is_what_the_next_step_runs
    executed = []
    executor = lambda do |text|
      executed << text
      replace_line(1, "verify the deployment") if executed.size == 1
      "ok"
    end

    PlanRunner.new(plan: @plan, log: @log, executor: executor).run

    assert_equal ["collect metrics", "verify the deployment", "report"], executed
    log = @log.doc.read_text("content")

    assert_includes log, "Done: verify the deployment -> ok"
    refute_includes log, "Running: verify\n"
    assert_includes log, "Plan complete."
  end

  def test_a_step_edited_while_it_runs_is_run_again_with_the_new_text
    executed = []
    executor = lambda do |text|
      executed << text
      replace_line(1, "verify twice") if text == "verify"
      "ok"
    end

    PlanRunner.new(plan: @plan, log: @log, executor: executor).run

    assert_equal ["collect metrics", "verify", "verify twice", "report"], executed
    assert_includes @log.doc.read_text("content"), "Changed while running, doing it again: verify twice"
  end

  def test_steps_added_while_running_are_picked_up
    executed = []
    executor = lambda do |text|
      executed << text
      @plan.edit { |doc| doc.get_text("content").push("celebrate\n") } if text == "report"
      "ok"
    end

    PlanRunner.new(plan: @plan, log: @log, executor: executor).run

    assert_equal ["collect metrics", "verify", "report", "celebrate"], executed
  end

  private

  # What a person does in a browser: change one line of the plan.
  def replace_line(index, replacement)
    @plan.edit do |doc|
      text = doc.get_text("content")
      lines = text.to_s.lines
      offset = lines[0...index].sum(&:length)
      text.delete(offset, lines[index].chomp.length)
      text.insert(offset, replacement)
    end
  end
end
