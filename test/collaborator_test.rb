# frozen_string_literal: true

require "test_helper"
require "y/collaborator"
require_relative "support/document_room"

# Y::Collaborator against a Rails app running the shipped Y::DocumentChannel: it
# joins with a grant, appears to the people in the document, reacts to
# their edits, and leaves when they do.
class CollaboratorTest < Minitest::Test
  include DocumentRoom

  # The collaborator the tests subclass, shown to people as Reviewer from the
  # moment it joins.
  class Reviewer < Y::Collaborator
    def initialize(...)
      super
      self.presence = { "user" => { "name" => "Reviewer", "color" => "#7c3aed" } }
    end
  end

  def collaborator(collaborator = Reviewer, **) = super

  def test_the_collaborator_answers_an_edit_and_leaves_when_the_person_does
    ada = person
    names = roster(ada)
    answers = Class.new(Reviewer) do
      def joined = edit { |doc| Y::Lexxy.append_paragraph(doc, "Reviewer here.") }
      def changed(blocks) = edit { |doc| Y::Lexxy.append_paragraph(doc, "Saw: #{blocks.map(&:text).join(" / ")}") }
    end
    run = collaborator(answers, idle: 1)

    wait_until { doc_of(ada).read_xml("root").to_s.include?("Reviewer here.") }
    wait_until { names.call.include?("Reviewer") }
    ada.edit { |doc| Y::Lexxy.append_paragraph(doc, "Please review.") }

    assert(wait_until { doc_of(ada).read_xml("root").to_s.include?("Saw: Please review.") })

    ada.unsubscribe

    # It waits one presence renewal window after joining before it can tell
    # it is alone, then `idle` more.
    assert_equal :left, run.join(Y::ActionCable::Client::RENEW + 10)&.value
  end

  # Outside a reactor, run starts one on the calling thread and holds it
  # until the collaborator leaves, so a job's thread is the collaborator's.
  def test_presence_can_change_while_the_collaborator_stays
    ada = person
    names = roster(ada)
    busy = Class.new(Reviewer) { def changed(_blocks) = self.presence = { "user" => { "name" => "Busy" } } }
    run = collaborator(busy)
    wait_until { names.call.include?("Reviewer") }
    ada.edit { |doc| Y::Lexxy.append_paragraph(doc, "Please review.") }

    assert(wait_until { names.call.include?("Busy") })
    run.kill
  end

  def test_the_collaborator_runs_on_the_calling_thread
    seen = Queue.new
    looks = Class.new(Reviewer) do
      define_method(:joined) do
        seen << [Thread.current, Async::Task.current?]
        leave
      end
    end
    run = collaborator(looks)

    assert_equal :left, run.join(10)&.value
    thread, task = seen.pop

    assert_equal run, thread
    assert task, "the collaborator runs in a reactor"
  end

  # On its reactor, the collaborator starts no threads: its connection and
  # its lock's renewals are tasks there, so a fiber job costs no thread.
  def test_the_collaborator_starts_no_threads_of_its_own
    seen = Queue.new
    looks = Class.new(Reviewer) do
      define_method(:joined) do
        seen << Thread.list.map(&:inspect)
        leave
      end
    end
    run = collaborator(looks)

    assert_equal :left, run.join(10)&.value
    assert_empty seen.pop.grep(%r{/lib/y/})
  end

  # changed gets the blocks themselves, so a block added above one while the
  # edits settle doesn't shift which block it sees. An update that reaches the
  # collaborator before its sync can touch no block yet, so changed may first
  # run with none.
  def test_a_block_added_above_during_the_pause_does_not_shift_what_changed_sees
    ada = person
    names = roster(ada)
    seen = Queue.new
    texts = Class.new(Reviewer) { define_method(:changed) { |blocks| seen << blocks.map(&:text) if blocks.any? } }
    run = collaborator(texts)
    wait_until { names.call.include?("Reviewer") }

    ada.edit { |doc| Y::Lexxy.append_paragraph(doc, "target") }
    ada.edit { |doc| doc.get_xml_text("root").insert_xml_text(0, Y::Lexical::PARAGRAPH_ATTRIBUTES) }

    assert_equal ["", "target"], seen.pop(timeout: 10)
    run.kill
  end

  # Someone who never pauses still gets an answer: changed runs after
  # SETTLE_AT_MOST seconds of steady typing.
  def test_steady_typing_reaches_changed_before_it_stops
    ada = person
    names = roster(ada)
    seen = Queue.new
    run = collaborator(Class.new(Reviewer) { define_method(:changed) { |blocks| seen << blocks } })
    wait_until { names.call.include?("Reviewer") }

    typing = Y::Collaborator::SETTLE_AT_MOST + 4
    stop = Process.clock_gettime(Process::CLOCK_MONOTONIC) + typing
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < stop && seen.empty?
      ada.edit { |doc| Y::Lexxy.append_paragraph(doc, "typing") }
      sleep 0.3
    end

    refute_empty seen, "changed ran while Ada was still typing"
    run.kill
  end

  # A change outside the root is a click, not typing, so it doesn't wait for
  # a pause.
  def test_a_change_outside_the_root_arrives_without_waiting
    ada = person
    names = roster(ada)
    seen = Queue.new
    run = collaborator(Class.new(Reviewer) { define_method(:changed) { |blocks| seen << blocks } })
    wait_until { names.call.include?("Reviewer") }

    asked = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ada.edit { |doc| doc.get_map("asks")["a1"] = "Make it shorter" }

    assert_equal [], seen.pop(timeout: 5)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - asked, :<, Y::Collaborator::SETTLE
    run.kill
  end

  def test_leave_ends_the_collaborator_without_waiting_to_be_alone
    run = collaborator(Class.new(Reviewer) { def joined = leave })

    assert_equal :left, run.join(5)&.value
  end

  def test_a_second_collaborator_on_the_same_document_is_turned_away
    @lock.write("yrby:collaborator:#{@document.key}", "another collaborator")

    assert_equal :busy, collaborator.join(5)&.value
  end

  # With as:, each person can bring one collaborator, and a second for the same
  # person is turned away.
  def test_one_collaborator_per_person_with_as
    @lock.write(Y::Collaborator::Lock.key(@document, "ada"), "Ada's collaborator")

    assert_equal :busy, collaborator(as: "ada").join(5)&.value
    assert_equal :left, collaborator(as: "linus", max_stay: 1).join(10)&.value
  end

  # An error in changed ends the collaborator the way it would end a job: the
  # collaborator clears its presence, gives up the lock, and the error raises
  # out of run.
  def test_an_error_in_changed_ends_the_collaborator_and_raises_out_of_run
    ada = person
    names = roster(ada)
    run = collaborator(Class.new(Reviewer) { def changed(_blocks) = raise("the model timed out") })

    wait_until { names.call.include?("Reviewer") }
    ada.edit { |doc| Y::Lexxy.append_paragraph(doc, "Please review.") }

    error = assert_raises(RuntimeError) { run.join(10) }

    assert_equal "the model timed out", error.message
    assert(wait_until { !names.call.include?("Reviewer") })
    assert_nil @lock.read("yrby:collaborator:#{@document.key}")
  end
end
