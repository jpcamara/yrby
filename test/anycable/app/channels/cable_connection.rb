# frozen_string_literal: true

# Identifies a connection by its ?user= param and refuses ?token=invalid. A
# real app reads a session cookie or a signed token here.
class CableConnection < Y::AnyCable::Connection
  def identify(request)
    return if request.params["token"] == "invalid"

    { "user" => request.params["user"] }
  end
end
