# frozen_string_literal: true

require "test_helper"
require "y/agent"
require "active_support"
require "active_support/cache"

class AgentLockTest < Minitest::Test
  def setup
    @store = ActiveSupport::Cache::MemoryStore.new
    @locks = []
  end

  def teardown
    @locks.each(&:release)
  end

  def lock
    Y::Agent::Lock.new(@store, "yrby:agent:doc").tap { |l| @locks << l }
  end

  def test_only_one_agent_takes_the_lock
    first = lock
    second = lock

    assert first.take
    refute second.take
    refute_predicate second, :held?
  end

  def test_a_renewal_that_finds_another_holder_gives_the_lock_up
    first = lock
    first.take
    @store.write("yrby:agent:doc", "another agent")
    first.send(:renew)

    refute_predicate first, :held?
    assert_equal "another agent", @store.read("yrby:agent:doc")
  end

  def test_a_renewal_keeps_the_lock_while_it_is_ours
    first = lock
    first.take
    @store.delete("yrby:agent:doc") # as if it had lapsed with nobody waiting
    first.send(:renew)

    assert_predicate first, :held?
    refute lock.take
  end

  def test_release_frees_the_lock_but_never_a_successors
    first = lock
    first.take
    first.release

    assert lock.take

    stale = lock
    stale.instance_variable_set(:@held, true) # it believes it still holds it
    stale.release

    refute_nil @store.read("yrby:agent:doc"), "the successor's lock survives"
  end
end
