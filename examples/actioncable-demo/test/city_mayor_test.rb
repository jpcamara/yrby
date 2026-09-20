# frozen_string_literal: true

require "city_helper"

# The mayor with a stand-in for the model: what it asks, and what it makes
# of the answers.
class CityMayorTest < Minitest::Test
  def mayor(reply = nil, &block)
    @prompts = []
    ask = lambda do |prompt|
      @prompts << prompt
      block ? block.call(prompt) : reply
    end
    CityMayor.new(ask: ask, logger: Logger.new(File::NULL))
  end

  def test_a_sign_is_read_as_one_of_the_instructions
    assert_equal :park, mayor("PARK").read("trees please")
    assert_equal :no_build, mayor("NO BUILD").read("leave my garden alone")
    assert_equal :clear, mayor("clear").read("tear it all down")
    assert_match(/"tear it all down"/, @prompts.last)
  end

  def test_a_sign_that_asks_for_nothing_reads_as_nothing
    assert_nil mayor("NONE").read("Main Street")
    assert_nil mayor("NONE. A name like this is not a request, so not NOBUILD either.").read("Main Street")
    assert_nil mayor("").read("Main Street")
    assert_equal :no_build, mayor("NOBUILD").read("keep off")
  end

  def test_a_name_is_one_clean_line
    assert_equal "Elm Street", mayor("\"Elm Street.\"\nIt is a fine name.").name("street")
    assert_equal "Old Mill Quarter", mayor("Old Mill Quarter").name("district", taken: ["Elm Street"])
    assert_match(/Already taken: Elm Street/, @prompts.last)
    assert_nil mayor("   ").name("street")
  end

  def test_a_model_failure_answers_nothing
    failing = mayor { raise "no model" }

    assert_nil failing.read("trees please")
    assert_nil failing.name("street")
    assert_equal 4, @prompts.size, "each question is tried twice"
  end

  def test_a_failure_on_the_first_try_is_asked_again
    flaky = mayor { |_prompt| @prompts.size == 1 ? raise("no model") : "SHOP" }

    assert_equal :shop, flaky.read("somewhere to buy milk")
  end

  def test_without_a_key_there_is_no_mayor
    assert_nil CityMayor.default
  end
end
