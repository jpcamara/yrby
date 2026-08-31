require "test_helper"

# The site accepts no files. This pins that, because it is the kind of policy a
# later "just add an image to the rich text demo" quietly undoes.
class NoUploadsTest < ActionDispatch::IntegrationTest
  test "Active Storage is never loaded" do
    # The gems ride in the lockfile transitively (lexxy-realtime depends on
    # the rails meta-gem), but nothing requires them: no constant, no engine,
    # no routes, no upload endpoint.
    assert_not defined?(ActiveStorage), "Active Storage must never be loaded"
  end

  test "Active Record is loaded (it is the document store), the rest are not" do
    assert Object.const_defined?("ActiveRecord"), "ActiveRecord backs Y::Document; it must be loaded"

    %w[ActionMailer ActionMailbox ActiveJob].each do |framework|
      assert_not Object.const_defined?(framework), "#{framework} should not be loaded"
    end

    # Action Text must never be loaded — lexxy-realtime's Collaborative
    # concern capability-detects it (`if respond_to?(:has_rich_text)`), and
    # this app relies on the plain-column path. ActionText::TagHelper is the
    # probe rather than the bare module name because loading the lexxy gem's
    # engine would define namespace shells.
    assert_not defined?(ActionText::TagHelper), "Action Text must never be loaded"
    assert_not Note.respond_to?(:has_rich_text), "Note must be on the plain-column path"
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

  test "the tiptap demo ships no image node" do
    bundle = Rails.root.join("public/tiptap.js")
    skip "run `cd frontend && bun run build` first" unless bundle.exist?

    # The paste/drop guards are the runtime half of the policy; this checks they
    # are actually in the shipped bundle rather than only in the source.
    assert_includes bundle.read, "dragover"
  end

  test "the lexxy bundle does not carry the upload client" do
    bundle = Rails.root.join("public/lexxy.js")
    skip "run `cd frontend && bun run build` first" unless bundle.exist?

    # @rails/activestorage is external and uninstalled; Lexxy only reaches its
    # dynamic import from the upload path, which attachments="false" disables.
    assert_not_includes bundle.read, "DirectUploadController",
                        "the ActiveStorage upload client must not be bundled"
  end
end
