require "test_helper"

# The site doesn't accept files. Action Text and Active Storage are loaded for
# the Lexxy demo's body, so these tests check each layer that keeps files out:
# no Active Storage routes, a storage service that refuses everything,
# read-only Active Storage records, a rich-text body that can't hold an
# attachment, and an editor with no upload URLs. "No uploads" in README.md
# describes them.
class NoUploadsTest < ActionDispatch::IntegrationTest
  ACTIVE_STORAGE_PATHS = {
    "/rails/active_storage/direct_uploads" => %i[get post],
    "/rails/active_storage/blobs/redirect/signed-id/x.png" => %i[get post],
    "/rails/active_storage/blobs/proxy/signed-id/x.png" => %i[get post],
    "/rails/active_storage/blobs/signed-id/x.png" => %i[get post],
    "/rails/active_storage/representations/redirect/signed-id/variation/x.png" => %i[get post],
    "/rails/active_storage/representations/proxy/signed-id/variation/x.png" => %i[get post],
    "/rails/active_storage/representations/signed-id/variation/x.png" => %i[get post],
    "/rails/active_storage/disk/encoded-key/x.png" => %i[get post],
    "/rails/active_storage/disk/encoded-token" => %i[get post put]
  }.freeze

  UPLOAD_PATH = /active_storage|direct_upload|blob|representation|disk|attachment/

  setup { Rack::Attack.cache.store.clear }

  def room = @room ||= Room.create!(slug: "no-uploads")

  def file = StringIO.new("GIF89a")

  NO_ROWS = { blobs: 0, attachments: 0, variants: 0 }.freeze

  def active_storage_rows
    { blobs: ActiveStorage::Blob.count, attachments: ActiveStorage::Attachment.count,
      variants: ActiveStorage::VariantRecord.count }
  end

  # Requirement 1: no Active Storage HTTP surface.

  test "Active Storage is configured to draw no routes" do
    assert_not ActiveStorage.draw_routes
    assert_same false, Rails.configuration.active_storage.draw_routes
  end

  test "the routes `bin/rails routes` prints include no Active Storage or upload route" do
    # The same inspector and formatter `bin/rails routes` uses, engines included.
    listing = ActionDispatch::Routing::RoutesInspector.new(Rails.application.routes.routes)
                                                      .format(ActionDispatch::Routing::ConsoleFormatter::Sheet.new)

    assert_includes listing, "demos#show", "the listing should have the app's routes"
    assert_no_match UPLOAD_PATH, listing

    paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }

    assert_empty paths.grep(UPLOAD_PATH)
    assert_empty Rails.application.routes.named_routes.names.grep(UPLOAD_PATH)
  end

  test "the router matches no Active Storage path, whatever the method" do
    ACTIVE_STORAGE_PATHS.each_key do |path|
      %w[GET POST PUT PATCH DELETE].each do |verb|
        assert_raises(ActionController::RoutingError, "#{verb} #{path} must not route") do
          Rails.application.routes.recognize_path(path, method: verb)
        end
        status, = Rails.application.routes.call(Rack::MockRequest.env_for(path, method: verb))

        assert_equal 404, status, "the router must answer #{verb} #{path} with a 404"
      end
    end
  end

  test "every Active Storage path 404s over HTTP, and writes are refused before routing" do
    ACTIVE_STORAGE_PATHS.each do |path, verbs|
      verbs.each do |verb|
        params = if verb == :post
                   { blob: { filename: "x.png", byte_size: 6, checksum: "x",
                             content_type: "image/png" } }
                 end
        process verb, path, params: params, as: (verb == :get ? nil : :json)

        if verb == :get
          assert_response :not_found, "GET #{path}"
        else
          # The method gate answers before routing (method_gate_test.rb), and
          # the router has no route behind it either (the test above).
          assert_response :method_not_allowed, "#{verb.upcase} #{path}"
        end
      end
    end

    assert_equal NO_ROWS, active_storage_rows
  end

  test "a multipart upload is refused on every path" do
    upload = Rack::Test::UploadedFile.new(StringIO.new("x" * 1024), "image/png", original_filename: "x.png")

    %w[/ /demos /docs/getting-started /rails/active_storage/direct_uploads /demos/lexxy/no-uploads].each do |path|
      %i[post put patch].each do |verb|
        process verb, path, params: { file: upload }

        assert_response :unsupported_media_type, "#{verb.upcase} #{path} must be refused before it's parsed"
      end
    end
  end

  # Requirement 2: a storage service that stores nothing.

  test "the only storage service is the refusing one" do
    assert_instance_of ActiveStorage::Service::RefusingService, ActiveStorage::Blob.service
    assert_equal({ "refusing" => { "service" => "Refusing" } },
                 Rails.configuration.active_storage.service_configurations.to_h.deep_stringify_keys)
  end

  test "the service refuses every read and write" do
    service = ActiveStorage::Blob.service
    calls = {
      upload: -> { service.upload("key", file) },
      download: -> { service.download("key") },
      download_chunk: -> { service.download_chunk("key", 0..1) },
      compose: -> { service.compose(%w[a b], "key") },
      delete: -> { service.delete("key") },
      delete_prefixed: -> { service.delete_prefixed("k") },
      exist?: -> { service.exist?("key") },
      url: lambda {
        service.url("key", expires_in: 60, filename: ActiveStorage::Filename.new("x.png"), disposition: :inline,
                           content_type: "image/png")
      },
      url_for_direct_upload: lambda {
        service.url_for_direct_upload("key", expires_in: 60, content_type: "image/png", content_length: 6,
                                             checksum: "x")
      },
      headers_for_direct_upload: lambda {
        service.headers_for_direct_upload("key", content_type: "image/png", checksum: "x")
      }
    }

    calls.each do |name, call|
      assert_raises(ActiveStorage::Service::RefusingService::Refused, "#{name} must raise", &call)
    end
  end

  test "creating a blob with an upload raises and leaves no row" do
    assert_raises(ActiveRecord::ReadOnlyRecord) do
      ActiveStorage::Blob.create_and_upload!(io: file, filename: "x.gif", content_type: "image/gif")
    end
    # The upload itself is refused too, for a blob that never reached the table.
    blob = ActiveStorage::Blob.build_after_unfurling(io: file, filename: "x.gif")

    assert_raises(ActiveStorage::Service::RefusingService::Refused) { blob.upload_without_unfurling(file) }
    assert_raises(ActiveRecord::ReadOnlyRecord) do
      ActiveStorage::Blob.create_before_direct_upload!(filename: "x.gif", byte_size: 6, checksum: "x")
    end
    assert_equal NO_ROWS, active_storage_rows
  end

  test "Active Storage records are read-only, so no attachment or variant row can be written" do
    # validate: false, so the save gets past "Blob must exist" to the write.
    assert_raises(ActiveRecord::ReadOnlyRecord) do
      ActiveStorage::Attachment.new(name: "embeds", record: room, blob_id: 1).save!(validate: false)
    end
    assert_raises(ActiveRecord::ReadOnlyRecord) do
      ActiveStorage::VariantRecord.new(blob_id: 1, variation_digest: "x").save!(validate: false)
    end
    assert_equal NO_ROWS, active_storage_rows
  end

  # Requirement 3: the document can't carry an attachment into the body.

  test "a crafted document renders with no attachment" do
    state = File.binread(File.expand_path("fixtures/lexxy_full.bin", __dir__))
    room.collaborative_document(:body).append(state)

    assert room.collaborative_document(:body).refresh
    rich_text = room.reload.body
    body = rich_text.body.to_html

    assert_includes body, "<h1>Heading One</h1>", "text content is kept"
    assert_not_includes body, "action-text-attachment", "attachment nodes render to nothing"
    assert_not_includes body, "attachment-gallery", "gallery wrappers render to nothing"
    assert_not_includes body, "data:", "no data: URLs reach the body"
    assert_empty rich_text.body.attachments
    assert_empty rich_text.embeds
    assert_equal NO_ROWS, active_storage_rows
  end

  test "attachments and forged or real signed ids rendered into the body are stripped when it's saved" do
    # The fixture rendered with Y::Lexxy's default rules, without Room's
    # suppression: a mention and an upload with a remote image URL, both as
    # <action-text-attachment>. One gets a forged sgid and the other a
    # correctly signed one, so the strip can't depend on the signature.
    doc = Y::Doc.new
    doc.apply_update(File.binread(File.expand_path("fixtures/lexxy_full.bin", __dir__)))
    html = Y::Lexxy.new(doc).to_html
                   .sub("SGID_MENTION_1", "forged--sgid")
                   .sub("SGID_UPLOAD_1", room.to_sgid(for: ActionText::Attachable::LOCATOR_NAME).to_s)

    assert_includes html, "<action-text-attachment", "the unsuppressed render should hold attachments"

    room.update!(body: html)
    rich_text = room.reload.body
    body = rich_text.body.to_html

    assert_includes body, "<h1>Heading One</h1>"
    assert_no_match(/action-text-attachment|sgid|forged|localhost:4111|<img/, body)
    assert_empty rich_text.body.attachments
    assert_empty rich_text.body.attachables
    assert_empty rich_text.embeds
    assert_equal NO_ROWS, active_storage_rows
  end

  test "every way of referencing a file is stripped from the body" do
    real_sgid = room.to_sgid(for: ActionText::Attachable::LOCATOR_NAME)
    trix = { sgid: real_sgid.to_s, url: "https://evil.example/x.png", contentType: "image/png" }.to_json
    html = <<~HTML
      <p>keep me</p>
      <action-text-attachment sgid="forged"></action-text-attachment>
      <action-text-attachment sgid="#{real_sgid}"></action-text-attachment>
      <action-text-attachment url="https://evil.example/x.png" content-type="image/png"></action-text-attachment>
      <action-text-attachment url="https://evil.example/x.mp4" content-type="video/mp4"></action-text-attachment>
      <action-text-attachment content-type="text/html" content="&lt;img src=x&gt;"></action-text-attachment>
      <figure data-trix-attachment="#{ERB::Util.html_escape(trix)}"></figure>
      <ACTION-TEXT-ATTACHMENT SGID="upper"></ACTION-TEXT-ATTACHMENT>
      <img src="https://evil.example/x.png"><img src="data:image/png;base64,AAAA"><img srcset="https://evil.example/x.png 1x">
      <picture><source srcset="https://evil.example/x.png"></picture>
      <video src="https://evil.example/x.mp4" poster="https://evil.example/p.png"></video>
      <audio src="https://evil.example/x.mp3"></audio><iframe src="https://evil.example"></iframe>
      <embed src="https://evil.example/x.swf"><object data="https://evil.example/x.swf"></object>
      <svg><image href="https://evil.example/x.png"></image></svg>
      <a href="data:text/html,hi">data link</a><a href="da&#9;ta:text/html,hi">tab link</a>
      <a href=" blob:https://evil.example/1">blob link</a><a href="https://example.com">kept link</a>
      <p style="background:url(https://evil.example/x.png)">styled</p>
      <p style="background:u\\72l(https://evil.example/x.png)">escaped</p>
      <span sgid="#{real_sgid}" gid="gid://site/Room/#{room.id}">refs</span>
    HTML

    room.update!(body: html)
    rich_text = room.reload.body
    body = rich_text.body.to_html

    ["keep me", "data link", "tab link", "blob link", "kept link", "styled", "escaped", "refs"].each do |text|
      assert_includes body, text, "text is kept"
    end
    assert_includes body, %(href="https://example.com"), "an ordinary link is kept"
    %w[action-text-attachment data-trix sgid gid= evil.example data: blob: <img <picture <source <video <audio
       <iframe <embed <object <svg url( \72].each do |marker|
      assert_not_includes body.downcase, marker
    end
    assert_empty rich_text.body.attachments
    assert_empty rich_text.body.attachables
    assert_empty rich_text.embeds
    assert_equal NO_ROWS, active_storage_rows
  end

  test "a rich text built or created directly is stripped too" do
    html = %(<p>x</p><action-text-attachment sgid="forged"></action-text-attachment>)

    assert_not_includes ActionText::RichText.new(body: html).body.to_html, "action-text-attachment"
    created = ActionText::RichText.create!(record: room, name: "body", body: html)

    assert_not_includes created.reload.body.to_html, "action-text-attachment"
    assert_empty created.embeds
    assert_equal NO_ROWS, active_storage_rows
  end

  test "no request can write a room's body" do
    room.update!(body: "<p>original</p>")
    path = "/demos/lexxy/#{room.slug}"
    attack = { room: { body: %(<action-text-attachment sgid="x"></action-text-attachment>) } }

    %i[post put patch].each do |verb|
      assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path(path, method: verb) }
      process verb, path, params: attack

      assert_response :method_not_allowed
    end
    get path, params: attack

    assert_response :success
    assert_equal "<p>original</p>", room.reload.body.body.to_html
    assert_empty(Rails.root.glob("app/controllers/**/*.rb").select { |f| f.read.match?(/\.permit\b|require\(:room\)/) })
  end

  # Requirement 4: the editor offers no upload.

  test "the lexxy editor renders with attachments off and no upload URL" do
    get "/demos/lexxy/#{room.slug}"

    assert_response :success
    editor = Nokogiri::HTML5(response.body).at_css("yrby-document lexxy-editor")

    assert editor, "the page should render the helper's editor"
    assert_equal "false", editor["attachments"]
    assert_empty editor.attribute_nodes.map(&:name).grep(/upload|blob|direct/)
    assert_no_match(%r{direct-upload|direct_upload|blob-url|blob_url|rails/active_storage}, response.body)
  end

  test "the page-wide file paste and drop block is in room.js" do
    source = Rails.root.join("frontend/src/room.js").read

    assert_match(/for \(const type of \["paste", "drop", "dragover"\]\)/, source)
    assert_includes source, "refuseFiles()"
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

  # Requirement 5: no model declares an attachment.

  test "no app model declares has_one_attached or has_many_attached" do
    sources = Rails.root.glob("{app,lib,config}/**/*.rb").select { |f| f.read.match?(/^\s*has_(one|many)_attached\b/) }

    assert_empty(sources.map { |f| f.relative_path_from(Rails.root).to_s })

    Rails.application.eager_load!
    with_attachments = ActiveRecord::Base.descendants.reject(&:abstract_class?)
                                         .select { |model| model.reflect_on_all_attachments.any? }.map(&:name)

    # Active Storage's own blob and variant records declare attachments, and
    # they're read-only (above). Action Text's rich text declares
    # `has_many_attached :embeds`, which the body writer keeps empty (above).
    framework = with_attachments.select { |name| name.start_with?("ActiveStorage::", "ActionText::") }

    assert_empty with_attachments - framework, "only Active Storage and Action Text models may declare attachments"
    assert_empty framework - %w[ActiveStorage::Blob ActiveStorage::VariantRecord ActionText::RichText ActionText::EncryptedRichText]
  end

  test "Action Mailer and Action Mailbox are not loaded" do
    %w[ActionMailer ActionMailbox].each do |framework|
      assert_not Object.const_defined?(framework), "#{framework} should not be loaded"
    end
  end

  test "every HTTP route is a GET but starting a room and inviting the agent" do
    # AnyCable's RPC endpoint matches any verb. Only the embedded anycable-go
    # calls it, over localhost with the AnyCable secret, and RoomGuarded
    # throttles every channel it reaches. Starting a room and inviting the
    # agent are POSTs with no body, which the method gate lets through only on
    # those paths.
    exceptions = ["/_anycable", "/demos/:demo/start(.:format)", "/demos/:demo/:room/start(.:format)",
                  "/demos/lexxy/:room/agent(.:format)"]
    routes = Rails.application.routes.routes.reject { |route| exceptions.include?(route.path.spec.to_s) }

    assert_equal ["GET"], routes.map(&:verb).uniq, "found a write endpoint, but this site only reads over HTTP"
  end
end
