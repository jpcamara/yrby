# frozen_string_literal: true

require "test_helper"
require "open3"

# Boot a minimal Rails app in a subprocess to exercise the engine
# initializers with real Action Text: the collaborative macros on
# ActiveRecord::Base, the FormBuilder prepends, materialization into an
# Action Text body, the encrypted wiring, and the yrby-forms adapter over
# the same base. A subprocess keeps the Rails boot from leaking into the
# rest of the suite.
class CollaborativeEngineBootTest < Minitest::Test
  def test_the_engine_boots_a_real_rails_application_with_action_text
    script = File.expand_path("support/collaborative_boot_check.rb", __dir__)
    output, status = Open3.capture2e("bundle", "exec", "ruby", script, chdir: File.expand_path("..", __dir__))

    assert_predicate status, :success?, "engine boot failed:\n#{output}"
    assert_includes output, "ENGINE BOOT OK"
  end
end
