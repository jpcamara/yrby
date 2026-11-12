# frozen_string_literal: true

require "test_helper"
require "y/collaborator"
require "active_support"
require "active_support/cache"

class CollaboratorLockTest < Minitest::Test
  def setup
    @store = ActiveSupport::Cache::MemoryStore.new
    @locks = []
  end

  # A lock renews itself in a task of the current reactor, so a test takes
  # locks on one, and releases them before the reactor waits for the task.
  def on_reactor
    Sync do
      yield
    ensure
      @locks.each(&:release)
    end
  end

  def lock
    Y::Collaborator::Lock.new(@store, "yrby:collaborator:doc").tap { |l| @locks << l }
  end

  def test_only_one_collaborator_takes_the_lock
    on_reactor do
      first = lock
      second = lock

      assert first.take
      refute second.take
      refute_predicate second, :held?
    end
  end

  def test_a_renewal_that_finds_another_holder_gives_the_lock_up
    on_reactor do
      first = lock
      first.take
      @store.write("yrby:collaborator:doc", "another collaborator")
      first.send(:renew)

      refute_predicate first, :held?
      assert_equal "another collaborator", @store.read("yrby:collaborator:doc")
    end
  end

  def test_a_renewal_keeps_the_lock_while_it_is_ours
    on_reactor do
      first = lock
      first.take
      @store.delete("yrby:collaborator:doc") # as if it had lapsed with nobody waiting
      first.send(:renew)

      assert_predicate first, :held?
      refute lock.take
    end
  end

  def test_release_frees_the_lock_but_never_a_successors
    on_reactor do
      first = lock
      first.take
      first.release

      assert lock.take

      stale = lock
      stale.instance_variable_set(:@held, true) # it believes it still holds it
      stale.release

      refute_nil @store.read("yrby:collaborator:doc"), "the successor's lock survives"
    end
  end

  Document = Data.define(:key)
  Person = Data.define(:to_global_id)

  def test_a_lock_per_document_or_per_document_and_person
    doc = Document.new(key: "post/1/body")

    assert_equal "yrby:collaborator:post/1/body", Y::Collaborator::Lock.key(doc, nil)
    assert_equal "yrby:collaborator:post/1/body:ada", Y::Collaborator::Lock.key(doc, "ada")
    assert_equal "yrby:collaborator:post/1/body:gid://app/Person/1",
                 Y::Collaborator::Lock.key(doc, Person.new(to_global_id: "gid://app/Person/1"))
  end
end
