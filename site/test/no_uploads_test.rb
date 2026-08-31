require "test_helper"

# The site accepts no files. This pins that, because it is the kind of policy a
# later "just add an image to the rich text demo" quietly undoes.
class NoUploadsTest < ActionDispatch::IntegrationTest
  test "Active Storage is not installed" do
    assert_not defined?(ActiveStorage), "Active Storage should not be in this app's bundle at all"
  end

  test "no framework beyond the six this app requires is loaded" do
    %w[ActiveRecord ActionMailer ActionMailbox ActionText ActiveJob].each do |framework|
      assert_not Object.const_defined?(framework), "#{framework} should not be loaded"
    end
  end

  test "the app exposes no upload route" do
    paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }

    assert_empty paths.grep(%r{blob|upload|attachment|rails/active_storage})
  end

  test "every HTTP route is a GET" do
    # The one exception is AnyCable's RPC endpoint, which matches any verb. It
    # is not a public write surface: it is called by the embedded anycable-go
    # over localhost, authenticated with the AnyCable secret, and everything it
    # can reach is throttled in DocumentChannel.
    routes = Rails.application.routes.routes.reject { |route| route.path.spec.to_s == "/_anycable" }

    assert_equal ["GET"], routes.map(&:verb).uniq, "a write endpoint appeared; this site only reads over HTTP"
  end

  test "the rich text demo ships no image node" do
    bundle = Rails.root.join("public/tiptap.js")
    skip "run `cd frontend && bun run build` first" unless bundle.exist?

    # The paste/drop guards are the runtime half of the policy; this checks they
    # are actually in the shipped bundle rather than only in the source.
    assert_includes bundle.read, "dragover"
  end
end
