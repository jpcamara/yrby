# A single record created ahead of time. Its collaborative body uses yrby's
# default store, and the room sweeper deletes its Y::Document state after a
# day with no activity.
class ExampleDocument < ApplicationRecord
end
