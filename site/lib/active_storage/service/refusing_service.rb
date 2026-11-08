# The site's only Active Storage service. It stores nothing and serves
# nothing: every call that would write, read, or link to a file raises.
#
# Action Text needs Active Storage loaded, but this site accepts no files.
# With no routes there's no HTTP way in, and this makes sure no code path
# inside the app can put a file anywhere either. config/storage.yml names it
# and config/application.rb selects it in every environment.
module ActiveStorage
  class Service::RefusingService < Service
    class Refused < StandardError; end

    %i[upload update_metadata download download_chunk compose delete delete_prefixed exist?
       url url_for_direct_upload headers_for_direct_upload].each do |method|
      define_method(method) { |*, **| refuse }
    end

    private

    def refuse
      raise Refused, "This site accepts no files, so Active Storage can't store or serve one."
    end
  end
end
