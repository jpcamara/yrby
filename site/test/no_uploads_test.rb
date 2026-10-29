require "test_helper"

# The site doesn't accept files. These tests check that, because a later
# change like adding images to the rich text demo could break it without
# anyone noticing. This file covers the frameworks, the boot guard
# (config/initializers/no_upload_frameworks.rb), and the routes. "No uploads"
# in README.md lists the other layers and their tests.
class NoUploadsTest < ActionDispatch::IntegrationTest
  test "the app booted with neither Active Storage nor Action Text" do
    assert_empty NoUploadFrameworks.loaded
    assert_not defined?(ActiveStorage::Engine)
    assert_not defined?(ActionText::Engine)
  end

  test "the boot guard names each upload framework it finds" do
    assert_equal ["Active Storage"], NoUploadFrameworks.loaded(->(name) { name == "ActiveStorage::Engine" })
    assert_equal ["Action Text"], NoUploadFrameworks.loaded(->(name) { name == "ActionText::Engine" })

    error = assert_raises(RuntimeError) { NoUploadFrameworks.check!(->(_name) { true }) }
    assert_includes error.message, "Active Storage and Action Text are loaded"
    assert_includes error.message, "accepts no uploads"
  end

  test "the boot guard runs in every environment" do
    initializer = Rails.root.join("config/initializers/no_upload_frameworks.rb").read

    assert_match(/^NoUploadFrameworks\.check!$/, initializer, "the check must run unconditionally at boot")
  end

  test "no route matches the Active Storage or direct upload paths" do
    %w[/rails/active_storage/blobs/redirect/x/y.png /rails/active_storage/disk/x/y.png
       /rails/active_storage/direct_uploads /rails/direct_uploads].each do |path|
      %i[get post put].each do |verb|
        assert_raises(ActionController::RoutingError, "#{verb.upcase} #{path} must not route") do
          Rails.application.routes.recognize_path(path, method: verb)
        end
      end
    end
  end

  test "Active Storage is not loaded" do
    # The gems are in the lockfile because lexxy-realtime depends on the rails
    # meta-gem, but nothing requires them. There's no constant, engine, route,
    # or upload endpoint.
    assert_not defined?(ActiveStorage), "Active Storage must not be loaded"
  end

  test "Active Record is loaded for the document store and the other frameworks are not" do
    assert Object.const_defined?("ActiveRecord"), "Y::Document uses ActiveRecord, so it must be loaded"

    # Active Job is loaded for the demo agent, on the in-process async adapter.
    # Active Storage would need it, but the boot guard refuses Active Storage
    # on its own.
    %w[ActionMailer ActionMailbox].each do |framework|
      assert_not Object.const_defined?(framework), "#{framework} should not be loaded"
    end

    # Action Text must not be loaded. lexxy-realtime's Collaborative concern
    # checks `respond_to?(:has_rich_text)`, and this app needs the plain column
    # path. The test checks ActionText::TagHelper because the lexxy gem's
    # engine can define an empty ActionText module.
    assert_not defined?(ActionText::TagHelper), "Action Text must not be loaded"
    assert_not Note.respond_to?(:has_rich_text), "Note must use a plain body column"
  end

  test "the app exposes no upload route" do
    paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }

    assert_empty paths.grep(%r{blob|upload|attachment|rails/active_storage})
  end

  test "every HTTP route is a GET but the agent invitation" do
    # AnyCable's RPC endpoint matches any verb. Only the embedded anycable-go
    # calls it, over localhost with the AnyCable secret, and RoomGuarded
    # throttles every channel it reaches. Inviting the agent is a POST with no
    # body, which the method gate lets through only on that path.
    exceptions = ["/_anycable", "/demos/lexxy/:room/agent(.:format)"]
    routes = Rails.application.routes.routes.reject { |route| exceptions.include?(route.path.spec.to_s) }

    assert_equal ["GET"], routes.map(&:verb).uniq, "found a write endpoint, but this site only reads over HTTP"
  end

  test "the tiptap bundle includes the file paste and drop guards" do
    bundle = Rails.root.join("public/tiptap.js")
    skip "run `cd frontend && bun run build` first" unless bundle.exist?

    # The paste and drop guards block files in the browser. This checks that
    # they're in the built bundle and not only in the source.
    assert_includes bundle.read, "dragover"
  end

  test "the lexxy bundle does not include the upload client" do
    bundle = Rails.root.join("public/lexxy.js")
    skip "run `cd frontend && bun run build` first" unless bundle.exist?

    # @rails/activestorage is external and not installed. Lexxy only imports it
    # from the upload path, and attachments="false" turns that off.
    assert_not_includes bundle.read, "DirectUploadController",
                        "the ActiveStorage upload client must not be bundled"
  end

  test "a multipart upload is refused on every path" do
    file = Rack::Test::UploadedFile.new(StringIO.new("x" * 1024), "image/png", original_filename: "x.png")

    %w[/ /demos /docs/getting-started /rails/active_storage/direct_uploads].each do |path|
      post path, params: { file: file }

      assert_response :unsupported_media_type, "POST #{path} must be refused before it's parsed"
      put path, params: { file: file }

      assert_response :unsupported_media_type, "PUT #{path} must be refused before it's parsed"
    end
  end

  test "rendering drops attachment nodes from a crafted document" do
    note = Note.create!(room: "no-uploads-probe")
    state = File.binread(File.expand_path("fixtures/lexxy_full.bin", __dir__))
    note.collaborative_document(:body).append(state)

    assert note.refresh_collaborative_rich_text(:body)
    body = note.reload.body

    assert_includes body, "<h1>Heading One</h1>", "text content is kept"
    assert_not_includes body, "action-text-attachment", "attachment nodes render to nothing"
    assert_not_includes body, "attachment-gallery", "gallery wrappers render to nothing"
    assert_not_includes body, "data:", "no data: URLs reach the stored column"
  ensure
    note&.destroy
  end
end
