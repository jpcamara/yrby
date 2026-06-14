# frozen_string_literal: true

# Selects the durable store. STORE_KIND=file uses the simple fsync'd append
# log (AuditLog); the default is the PostgreSQL store (PgStore). Both expose
# record / replay / entries / reset!.
module Store
  module_function

  def current
    ENV["STORE_KIND"] == "file" ? AuditLog : PgStore
  end
end
