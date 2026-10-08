# The code samples on the Lexxy page. They live in Ruby so the template's ERB
# parser never sees the `<%= ... %>` in the form snippets. added_lines_code and
# code_block come from ApplicationHelper.
module LexxyPageHelper
  def sample_lexxy_model
    added_lines_code(<<~RUBY, add: ["has_collaborative_rich_text"])
      class Post < ApplicationRecord
        has_collaborative_rich_text :body
      end
    RUBY
  end

  def sample_lexxy_form
    added_lines_code(<<~ERB, add: ["collaborative_rich_textarea"])
      <%= form.collaborative_rich_textarea :body %>
    ERB
  end

  def sample_lexxy_install
    added_lines_code(<<~BASH, add: ["lexxy_realtime:install"])
      bin/rails generate lexxy_realtime:install && bin/rails db:migrate
    BASH
  end

  # The longer Lexxy page samples, with syntax highlighting.
  def sample_lexxy_markup
    code_block "html", <<~HTML
      <yrby-document grant="..." name="body" channel="LexxyRealtime::DocumentChannel">
        <lexxy-editor>
          <lexxy-collaboration doc-id="post-42-body" name="Ada" color="#3b82f6">
          </lexxy-collaboration>
        </lexxy-editor>
      </yrby-document>
    HTML
  end

  def sample_lexxy_authorize
    code_block "ruby", <<~RUBY
      # config/initializers/lexxy_realtime.rb
      Rails.application.config.to_prepare do
        LexxyRealtime::DocumentChannel.authorize_document do |record, name|
          record.editable_by?(current_user, attribute: name)
        end
      end
    RUBY
  end

  def sample_lexxy_refresh_form
    code_block "erb", <<~ERB
      <%= form.collaborative_rich_textarea :body, expires_in: 10.minutes,
                                                   refresh: grant_post_path(@post) %>
    ERB
  end

  def sample_lexxy_refresh_action
    code_block "ruby", <<~RUBY
      # config/routes.rb: resources :posts do get :grant, on: :member end
      def grant
        @post = current_user.posts.find(params[:id]) # your own authorization, again
        render json: { grant: @post.collaborative_rich_text_grant(:body, expires_in: 10.minutes) }
      end
    RUBY
  end

  def sample_lexxy_pins
    code_block "ruby", <<~RUBY
      # config/importmap.rb, added by the generator
      pin "@37signals/lexxy", to: "lexxy.js"
      pin "lexxy-realtime", to: "lexxy_realtime/lexxy-realtime.js"
      pin "yrby-client", to: "lexxy_realtime/yrby-client.js"
      pin "yrby-client/element", to: "lexxy_realtime/yrby-client.js"
      pin "yjs", to: "lexxy_realtime/yjs.js"
      pin "@rails/actioncable", to: "actioncable.esm.js"
      pin "@rails/activestorage", to: "activestorage.esm.js"
    RUBY
  end

  def sample_lexxy_imports
    code_block "js", <<~JS
      import "@37signals/lexxy"
      import "lexxy-realtime" // registers <lexxy-collaboration> and <yrby-document>
    JS
  end

  def sample_lexxy_anycable
    code_block "js", <<~JS
      import { createConsumer } from "@anycable/web"
      import { setConsumer } from "lexxy-realtime"

      setConsumer(() => createConsumer())
    JS
  end
end
